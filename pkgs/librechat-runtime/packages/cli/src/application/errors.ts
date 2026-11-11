import type { AccountInspectionError } from "@dotfiles/librechat-runtime/account-inspection";
import type {
  BootstrapAccountMismatchError,
  BootstrapRegistrationError,
} from "@dotfiles/librechat-runtime/native-bootstrap";

interface CommandArgumentIssue {
  path?: readonly PropertyKey[];
}

export abstract class UsageError extends Error {
  readonly status = 2;

  constructor(options?: ErrorOptions) {
    super(undefined, options);
    this.name = new.target.name;
  }
}

export abstract class OperationalError extends Error {
  readonly status = 1;

  constructor(options?: ErrorOptions) {
    super(undefined, options);
    this.name = new.target.name;
  }
}

export class CancelledError extends Error {
  readonly status = 130;

  constructor() {
    super("Cancelled. No changes were made.");
    this.name = "CancelledError";
  }
}

export class InteractiveInputUnavailableError extends UsageError {
  override readonly message =
    "Interactive input is unavailable. Supply the required command options.";
}

export class InvalidEmailError extends UsageError {
  override readonly message = "Invalid email address";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class InvalidDisplayNameError extends UsageError {
  override readonly message = "Use a display name of 3 to 80 characters.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class InvalidConversationError extends UsageError {
  override readonly message = "Invalid UUID";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class PasswordTooShortError extends UsageError {
  readonly minimum: number;

  constructor(minimum: number) {
    super();
    this.minimum = minimum;
    this.message = `Password must contain at least ${minimum} characters.`;
  }
}

export class PasswordTooLongError extends UsageError {
  readonly maximum: number;

  constructor(maximum: number) {
    super();
    this.maximum = maximum;
    this.message = `Password must contain at most ${maximum} characters.`;
  }
}

export class PasswordRejectedError extends UsageError {
  override readonly message =
    "Use a non-blank password accepted by LibreChat's password policy.";
}

export class PasswordConfirmationError extends UsageError {
  override readonly message = "The passwords did not match.";
}

export class PasswordFileRequiredError extends UsageError {
  override readonly message =
    "Non-interactive bootstrap of a new account requires --password-file. Run in a terminal to enter a password interactively.";
}

export class BootstrapOptionsRequiredError extends UsageError {
  readonly options: readonly ("--email" | "--name")[];

  constructor(options: readonly ("--email" | "--name")[]) {
    super();
    this.options = options;
    this.message = `Non-interactive bootstrap requires ${options.join(" and ")}.\nFor a new account, also provide --password-file. Run in a terminal to enter these values interactively.`;
  }
}

export class ResetOptionsRequiredError extends UsageError {
  readonly options: readonly ("--conversation" | "--yes")[];

  constructor(options: readonly ("--conversation" | "--yes")[]) {
    super();
    this.options = options;
    this.message = `Non-interactive reset requires ${options.join(" and ")}. Run in a terminal to enter the conversation UUID and confirm deletion.`;
  }
}

export class HookInputError extends UsageError {
  override readonly message =
    "Invalid conversation hook input. Expected a session_id UUID in JSON.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class ArchiveArgumentsUsageError extends UsageError {
  override readonly message =
    "Invalid arguments. Run librechat-runtime archive session --help for bounded query options.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class CommandArgumentsError extends UsageError {
  readonly entry: "public" | "runtime";
  readonly path: readonly string[];
  readonly issues: readonly CommandArgumentIssue[];

  constructor(
    entry: "public" | "runtime",
    path: readonly string[],
    issues: readonly CommandArgumentIssue[] = [],
  ) {
    super();
    this.entry = entry;
    this.path = path;
    this.issues = issues;
    const program = entry === "public" ? "librechatctl" : "librechat-runtime";
    const descriptions: Readonly<Record<string, string>> = {
      email: "Use a valid email address for --email.",
      name: "Use --name with a display name of 3 to 80 characters.",
      passwordFile: "Use --password-file with a non-empty file path.",
      conversation: "Use --conversation with a valid UUID.",
      manifest: "Provide the deployment manifest path.",
      file: "Provide the service configuration file path.",
      limit: "Use --limit with an integer from 1 to 500.",
    };
    const key = issues
      .map((issue) => issue.path?.[0])
      .find(
        (value) =>
          typeof value === "string" && descriptions[value] !== undefined,
      );
    const detail = typeof key === "string" ? descriptions[key] : undefined;
    const help = [program, ...path, "--help"].join(" ");
    this.message = [
      "Invalid arguments.",
      ...(detail === undefined ? [] : [detail]),
      `Run ${help} for usage.`,
    ].join(" ");
  }
}

export class DeploymentMissingError extends OperationalError {
  override readonly message =
    "No LibreChat deployment is configured. Use the librechatctl installed by Home Manager.";
}

export class DeploymentConfigurationError extends OperationalError {
  override readonly message =
    "Could not read the LibreChat deployment configuration. Check the installed librechatctl wrapper and rebuild the deployment if necessary.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class PasswordFileReadError extends OperationalError {
  override readonly message =
    "Could not read --password-file. Check that the file exists and is readable.";

  readonly file: string;

  constructor(file: string, cause: unknown) {
    super({ cause });
    this.file = file;
  }
}

export class AccountInspectionOperationError extends OperationalError {
  constructor(cause: AccountInspectionError) {
    super({ cause });
    this.message = cause.message;
  }
}

export class AccountBindingMismatchError extends OperationalError {
  constructor(cause: BootstrapAccountMismatchError) {
    super({ cause });
    this.message = cause.message;
  }
}

export class AccountRegistrationRefusedError extends OperationalError {
  constructor(cause: BootstrapRegistrationError) {
    super({ cause });
    this.message = cause.message;
  }
}

export class UnexpectedPasswordPolicyIssueError extends OperationalError {
  override readonly message =
    "The installed LibreChat password policy returned an unsupported result.";

  constructor(_issue: never) {
    super();
  }
}

export class NativeApiIncompatibleError extends OperationalError {
  override readonly message =
    "The installed LibreChat native API is incompatible. Rebuild the LibreChat deployment with matching packages.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class BootstrapOperationError extends OperationalError {
  override readonly message =
    "Could not bootstrap LibreChat. Check that the LibreChat services are running and consult their logs.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class PasswordPolicyUnavailableError extends OperationalError {
  override readonly message =
    "The installed LibreChat password policy could not be loaded. Rebuild the deployment with matching packages.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class ResetRefusedError extends OperationalError {
  override readonly message =
    "The controller refused the workspace reset. Finish active calls and check the conversation UUID.";
  readonly httpStatus: number;

  constructor(httpStatus: number) {
    super();
    this.httpStatus = httpStatus;
  }
}

export class ControllerUnavailableError extends OperationalError {
  override readonly message =
    "Could not contact the conversation controller. Start the LibreChat services and try again.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class HostStartupError extends OperationalError {
  override readonly message =
    "Could not start the LibreChat host services. Check the service logs.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class GuestStartupError extends OperationalError {
  override readonly message =
    "Could not start the LibreChat guest service. Check its configuration and logs.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class GuestOperationError extends OperationalError {
  override readonly message =
    "The LibreChat guest operation failed. Check the guest service logs.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class ArchiveQueryError extends OperationalError {
  override readonly message =
    "The read-only AgentsView archive query failed. Check the archive service.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class ArchiveHttpError extends OperationalError {
  override readonly message =
    "The read-only AgentsView archive query failed. Check the archive service.";
  readonly httpStatus: number;

  constructor(httpStatus: number) {
    super();
    this.httpStatus = httpStatus;
  }
}

export class WorkspaceReminderError extends OperationalError {
  override readonly message =
    "The conversation controller could not prepare the workspace reminder. Check the LibreChat services.";

  constructor(cause: unknown) {
    super({ cause });
  }
}

export class WorkspaceReminderHttpError extends OperationalError {
  override readonly message =
    "The conversation controller could not prepare the workspace reminder. Check the LibreChat services.";
  readonly httpStatus: number;

  constructor(httpStatus: number) {
    super();
    this.httpStatus = httpStatus;
  }
}
