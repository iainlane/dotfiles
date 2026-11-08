import { z } from "zod";
import type { BootstrapInput } from "@dotfiles/librechat-runtime/bootstrap";
import {
  CancelledError,
  OperationalError,
  UsageError,
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

function validated(schema: z.ZodType<string>, value: string): string {
  const result = schema.safeParse(value);
  if (!result.success) {
    throw new UsageError(result.error.issues[0]?.message ?? "Invalid input.");
  }
  return result.data;
}

function missingOptions(options: string[]): string {
  return options.join(" and ");
}

function acceptedPassword(password: string, accounts: AccountAccess): string {
  const issue = accounts.passwordIssue(password);
  if (issue !== undefined) {
    throw new UsageError(issue);
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
    throw new OperationalError(
      "Could not read --password-file. Check that the file exists and is readable.",
      { cause },
    );
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
    throw new UsageError(
      "Non-interactive bootstrap of a new account requires --password-file. Run in a terminal to enter a password interactively.",
    );
  }

  const password = acceptedPassword(
    await prompts.password({
      message: "Password",
      validate: (value) => accounts.passwordIssue(value),
    }),
    accounts,
  );
  const repeated = await prompts.password({
    message: "Repeat password",
    validate: (value) =>
      value === password ? undefined : "The passwords did not match.",
  });

  if (repeated !== password) {
    throw new UsageError("The passwords did not match.");
  }
  return password;
}

export function requireBootstrapOptions(
  options: BootstrapOptions,
  prompts: Prompts,
): void {
  const missing = [
    ...(options.email === undefined ? ["--email"] : []),
    ...(options.name === undefined ? ["--name"] : []),
  ];

  if (!prompts.interactive && missing.length > 0) {
    throw new UsageError(
      `Non-interactive bootstrap requires ${missingOptions(missing)}.\nFor a new account, also provide --password-file. Run in a terminal to enter these values interactively.`,
    );
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
  const missing = [
    ...(options.conversation === undefined ? ["--conversation"] : []),
    ...(options.yes ? [] : ["--yes"]),
  ];
  if (!prompts.interactive && missing.length > 0) {
    throw new UsageError(
      `Non-interactive reset requires ${missingOptions(missing)}. Run in a terminal to enter the conversation UUID and confirm deletion.`,
    );
  }

  const conversation = validated(
    conversationSchema,
    options.conversation ??
      (await prompts.text({
        message: "Conversation UUID",
        validate: (value) => validation(conversationSchema, value),
      })),
  );
  if (
    !options.yes &&
    !(await prompts.confirm("Delete this workspace, including unpushed work?"))
  ) {
    throw new CancelledError();
  }
  return conversation;
}
