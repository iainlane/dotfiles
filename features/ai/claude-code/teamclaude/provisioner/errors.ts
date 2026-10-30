export type ValidationSource =
  | "configuration"
  | "specification"
  | "default-configuration"
  | "config-library"
  | "account-library";

export abstract class ProvisionError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = new.target.name;
  }
}

export class InvalidArgumentsError extends ProvisionError {
  constructor() {
    super("Use provision.ts <TeamClaude config module> <specification>");
  }
}

export class InvalidJsonError extends ProvisionError {
  readonly path: string;

  constructor(path: string) {
    super(`Invalid JSON in ${path}`);
    this.path = path;
  }
}

export class InvalidDataError extends ProvisionError {
  readonly source: ValidationSource;
  readonly path: string | null;
  readonly fields: PropertyKey[][];

  constructor(
    source: ValidationSource,
    path: string | null,
    fields: PropertyKey[][],
  ) {
    const location = path === null ? "" : ` in ${path}`;
    super(
      `Invalid ${source}${location} at: ${fields.map((field) => field.join(".")).join(", ")}`,
    );
    this.source = source;
    this.path = path;
    this.fields = fields;
  }
}

export class FileReadError extends ProvisionError {
  readonly path: string;

  constructor(path: string, options: ErrorOptions) {
    super(`Could not read ${path}`, options);
    this.path = path;
  }
}

export class ConfigurationWriteError extends ProvisionError {
  readonly path: string;

  constructor(path: string, options: ErrorOptions) {
    super(`Could not update configuration at ${path}`, options);
    this.path = path;
  }
}

export class AccountsSettingError extends ProvisionError {
  constructor() {
    super("Declare accounts through apiKeyAccounts, not settings");
  }
}

export class UnsupportedFieldError extends ProvisionError {
  readonly field: string;

  constructor(field: string) {
    super(`Unsupported configuration field: ${field}`);
    this.field = field;
  }
}

export class ApiKeyAccountConflictError extends ProvisionError {
  readonly account: string;

  constructor(account: string) {
    super(`API-key account ${account} conflicts with existing accounts`);
    this.account = account;
  }
}

export class AmbiguousAccountPolicyError extends ProvisionError {
  readonly account: string;

  constructor(account: string) {
    super(`Account policy ${account} matches multiple accounts`);
    this.account = account;
  }
}

export class InvalidApiKeyError extends ProvisionError {
  readonly path: string;

  constructor(path: string) {
    super(`Expected a single API key in ${path}`);
    this.path = path;
  }
}

export class SopsDecryptionError extends ProvisionError {
  readonly program: string;

  constructor(program: string) {
    super(`sops-nix failed to decrypt secrets with ${program}`);
    this.program = program;
  }
}

export class SopsTimeoutError extends ProvisionError {
  readonly program: string;

  constructor(program: string) {
    super(`Timed out waiting for sops-nix to decrypt secrets with ${program}`);
    this.program = program;
  }
}

export class ReloadHttpError extends ProvisionError {
  readonly status: number;

  constructor(status: number) {
    super(`TeamClaude configuration reload returned ${status}`);
    this.status = status;
  }
}

export class ReloadTransportError extends ProvisionError {
  constructor(options: ErrorOptions) {
    super(
      "Could not connect to TeamClaude to reload its configuration",
      options,
    );
  }
}
