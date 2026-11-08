import type { BootstrapInput } from "@dotfiles/librechat-runtime/bootstrap";

export interface AccountSummary {
  exists: boolean;
  name: string | undefined;
}

export interface AccountAccess {
  binding(): Promise<{ email: string } | null>;
  inspect(email: string): Promise<AccountSummary>;
  passwordIssue(password: string): string | undefined;
  bootstrap(input: BootstrapInput): Promise<void>;
}

export interface TextRequest {
  message: string;
  initialValue?: string;
  validate(value: string): string | undefined;
}

export interface Prompts {
  readonly interactive: boolean;
  text(request: TextRequest): Promise<string>;
  password(request: Omit<TextRequest, "initialValue">): Promise<string>;
  confirm(message: string): Promise<boolean>;
}

export interface Presentation extends Prompts {
  intro(message: string): void;
  info(message: string): void;
  success(message: string): void;
  outro(message: string): void;
  error(message: string): void;
  cancel(message: string): void;
  progress<T>(message: string, operation: () => Promise<T>): Promise<T>;
}

export interface FileAccess {
  readText(file: string): Promise<string>;
}

export interface Deployment {
  readonly accounts: AccountAccess;
  readonly url: string;
  resetWorkspace(conversation: string): Promise<void>;
}

export interface RuntimeServices {
  serve(file: string): Promise<void>;
  guest(file: string): Promise<void>;
  hook(file: string): Promise<void>;
  archive(query: string[]): Promise<string>;
}

export interface CommandDependencies {
  readonly manifest: string | undefined;
  readonly presentation: Presentation;
  readonly files: FileAccess;
  readonly services: RuntimeServices;
  openDeployment(file: string): Promise<Deployment>;
  writeOutput(text: string): void;
}
