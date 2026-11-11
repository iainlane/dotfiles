import { z } from "zod";
import type {
  BootstrapInput,
  PasswordPolicyIssue,
} from "@dotfiles/librechat-runtime/bootstrap";
import {
  BootstrapOptionsRequiredError,
  CancelledError,
  InvalidConversationError,
  InvalidDisplayNameError,
  InvalidEmailError,
  PasswordConfirmationError,
  PasswordFileReadError,
  PasswordFileRequiredError,
  PasswordRejectedError,
  PasswordTooLongError,
  PasswordTooShortError,
  ResetOptionsRequiredError,
  UnexpectedPasswordPolicyIssueError,
  type UsageError,
} from "#cli/application/errors";
import type {
  AccountAccess,
  FileAccess,
  Prompts,
} from "#cli/application/ports";
import {
  conversationSchema,
  displayNameSchema,
  emailSchema,
  type BootstrapOptions,
} from "#cli/definitions/commands";

type ValidationError = new (cause: unknown) => UsageError;

export function interactiveMode(input: {
  stdinTTY: boolean | undefined;
  stderrTTY: boolean | undefined;
  ci: string | undefined;
}): boolean {
  const ci =
    input.ci !== undefined &&
    !["", "0", "false"].includes(input.ci.toLowerCase());
  return input.stdinTTY === true && input.stderrTTY === true && !ci;
}

function validation(
  schema: z.ZodType<string>,
  value: string,
): string | undefined {
  const result = schema.safeParse(value);
  return result.success ? undefined : result.error.issues[0]?.message;
}

function validated(
  schema: z.ZodType<string>,
  value: string,
  Failure: ValidationError,
): string {
  const result = schema.safeParse(value);
  if (!result.success) {
    throw new Failure(result.error);
  }
  return result.data;
}

function passwordError(issue: PasswordPolicyIssue): UsageError {
  switch (issue.kind) {
    case "minimum":
      return new PasswordTooShortError(issue.minimum);
    case "maximum":
      return new PasswordTooLongError(issue.maximum);
    case "rejected":
      return new PasswordRejectedError();
  }
  throw new UnexpectedPasswordPolicyIssueError(issue);
}

function acceptedPassword(password: string, accounts: AccountAccess): string {
  const issue = accounts.passwordIssue(password);
  if (issue !== undefined) {
    throw passwordError(issue);
  }
  return password;
}

async function readPasswordFile(
  file: string,
  files: FileAccess,
): Promise<string> {
  try {
    return (await files.readText(file)).replace(/\r?\n$/u, "");
  } catch (cause) {
    throw new PasswordFileReadError(file, cause);
  }
}

async function passwordInput(
  options: BootstrapOptions,
  {
    accounts,
    files,
    prompts,
  }: { accounts: AccountAccess; files: FileAccess; prompts: Prompts },
): Promise<string> {
  if (options.passwordFile !== undefined) {
    return acceptedPassword(
      await readPasswordFile(options.passwordFile, files),
      accounts,
    );
  }
  if (!prompts.interactive) {
    throw new PasswordFileRequiredError();
  }
  const password = acceptedPassword(
    await prompts.password({
      message: "Password",
      validate: (value) => {
        const issue = accounts.passwordIssue(value);
        return issue === undefined ? undefined : passwordError(issue).message;
      },
    }),
    accounts,
  );
  const repeated = await prompts.password({
    message: "Repeat password",
    validate: (value) =>
      value === password ? undefined : "The passwords did not match.",
  });
  if (repeated !== password) {
    throw new PasswordConfirmationError();
  }
  return password;
}

export function requireBootstrapOptions(
  options: BootstrapOptions,
  prompts: Prompts,
): void {
  const missing: ("--email" | "--name")[] = [
    ...(options.email === undefined ? ["--email" as const] : []),
    ...(options.name === undefined ? ["--name" as const] : []),
  ];
  if (!prompts.interactive && missing.length > 0) {
    throw new BootstrapOptionsRequiredError(missing);
  }
}

export async function resolveBootstrapInputs(
  options: BootstrapOptions,
  dependencies: {
    accounts: AccountAccess;
    files: FileAccess;
    prompts: Prompts;
  },
): Promise<{ input: BootstrapInput; existing: boolean }> {
  const { accounts, prompts } = dependencies;
  requireBootstrapOptions(options, prompts);
  const binding = options.email === undefined ? await accounts.binding() : null;
  const email = validated(
    emailSchema,
    options.email ??
      (await prompts.text({
        message: "Email address",
        initialValue: binding?.email,
        validate: (value) => validation(emailSchema, value),
      })),
    InvalidEmailError,
  );
  const summary = await accounts.inspect(email);
  const name = validated(
    displayNameSchema,
    options.name ??
      (await prompts.text({
        message: "Display name",
        initialValue: summary.name,
        validate: (value) => validation(displayNameSchema, value),
      })),
    InvalidDisplayNameError,
  );
  const password = summary.exists
    ? undefined
    : await passwordInput(options, dependencies);
  return { input: { email, name, password }, existing: summary.exists };
}

export async function resolveWorkspaceInput(
  options: { conversation: string | undefined; yes: boolean },
  prompts: Prompts,
): Promise<string> {
  const missing: ("--conversation" | "--yes")[] = [
    ...(options.conversation === undefined ? ["--conversation" as const] : []),
    ...(options.yes ? [] : ["--yes" as const]),
  ];
  if (!prompts.interactive && missing.length > 0) {
    throw new ResetOptionsRequiredError(missing);
  }
  const conversation = validated(
    conversationSchema,
    options.conversation ??
      (await prompts.text({
        message: "Conversation UUID",
        validate: (value) => validation(conversationSchema, value),
      })),
    InvalidConversationError,
  );
  if (
    !options.yes &&
    !(await prompts.confirm("Delete this workspace, including unpushed work?"))
  ) {
    throw new CancelledError();
  }
  return conversation;
}
