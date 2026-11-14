import type {
  BootstrapInput,
  PasswordPolicyIssue,
} from "@dotfiles/librechat-runtime/bootstrap";
import {
  CancelledError,
  InteractiveInputUnavailableError,
} from "#cli/application/errors";
import type {
  AccountAccess,
  AccountSummary,
  FileAccess,
  Presentation,
  TextRequest,
} from "#cli/application/ports";

export class DeploymentUnreachableError extends Error {
  constructor() {
    super("The deployment is unreachable");
    this.name = "DeploymentUnreachableError";
  }
}

class FileMissingError extends Error {
  constructor(file: string) {
    super(`No such file: ${file}`);
    this.name = "FileMissingError";
  }
}

export class FakeAccounts implements AccountAccess {
  readonly accounts: Map<string, { name: string; password?: string }>;
  private readonly bound: { email: string } | null;
  private readonly failure: Error | undefined;

  constructor(
    options: {
      accounts?: Record<string, { name: string }>;
      bound?: string;
      failure?: Error;
    } = {},
  ) {
    this.accounts = new Map(Object.entries(options.accounts ?? {}));
    this.bound = options.bound === undefined ? null : { email: options.bound };
    this.failure = options.failure;
  }

  private available(): void {
    if (this.failure !== undefined) {
      throw this.failure;
    }
  }

  async binding(): Promise<{ email: string } | null> {
    this.available();
    return this.bound;
  }

  async inspect(email: string): Promise<AccountSummary> {
    this.available();
    const account = this.accounts.get(email);
    return { exists: account !== undefined, name: account?.name };
  }

  passwordIssue(password: string): PasswordPolicyIssue | undefined {
    return password.length < 8 ? { kind: "minimum", minimum: 8 } : undefined;
  }

  async bootstrap({ email, name, password }: BootstrapInput): Promise<void> {
    this.available();
    const existing = this.accounts.get(email);
    this.accounts.set(
      email,
      existing === undefined ? { name, password } : { ...existing, name },
    );
  }
}

export class FakeFiles implements FileAccess {
  private readonly files: Map<string, string>;

  constructor(files: Record<string, string> = {}) {
    this.files = new Map(Object.entries(files));
  }

  async readText(file: string): Promise<string> {
    const text = this.files.get(file);
    if (text === undefined) {
      throw new FileMissingError(file);
    }
    return text;
  }
}

export class FakeTerminal implements Presentation {
  readonly interactive: boolean;
  readonly screen: string[] = [];
  private readonly answers: Record<string, readonly string[]>;

  constructor(
    options: {
      interactive?: boolean;
      answers?: Record<string, readonly string[]>;
    } = {},
  ) {
    this.interactive = options.interactive ?? true;
    this.answers = options.answers ?? {};
  }

  private prompt(line: string): void {
    if (!this.interactive) {
      throw new InteractiveInputUnavailableError();
    }
    this.screen.push(line);
  }

  private ask(request: Omit<TextRequest, "initialValue">): string {
    for (const attempt of this.answers[request.message] ?? []) {
      const problem = request.validate(attempt);
      if (problem === undefined) {
        return attempt;
      }
      this.screen.push(`! ${problem}`);
    }
    throw new CancelledError();
  }

  async text(request: TextRequest): Promise<string> {
    this.prompt(
      request.initialValue === undefined
        ? `? ${request.message}`
        : `? ${request.message} [${request.initialValue}]`,
    );
    return this.ask(request);
  }

  async password(request: Omit<TextRequest, "initialValue">): Promise<string> {
    this.prompt(`? ${request.message} (hidden)`);
    return this.ask(request);
  }

  async confirm(message: string): Promise<boolean> {
    this.prompt(`? ${message} (y/N)`);
    return this.answers[message]?.at(0) === "y";
  }

  intro(message: string): void {
    if (this.interactive) {
      this.screen.push(`┌ ${message}`);
    }
  }

  info(message: string): void {
    this.screen.push(message);
  }

  success(message: string): void {
    this.screen.push(message);
  }

  outro(message: string): void {
    if (this.interactive) {
      this.screen.push(`└ ${message}`);
    }
  }

  error(message: string): void {
    this.screen.push(`Error: ${message}`);
  }

  cancel(message: string): void {
    this.screen.push(message);
  }

  async progress<T>(message: string, operation: () => Promise<T>): Promise<T> {
    if (this.interactive) {
      this.screen.push(`… ${message}`);
    }
    return await operation();
  }
}
