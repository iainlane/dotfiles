import type { Readable, Writable } from "node:stream";
import * as clack from "@clack/prompts";
import {
  CancelledError,
  InteractiveInputUnavailableError,
} from "#cli/application/errors";
import type { Presentation, TextRequest } from "#cli/application/ports";

export class TerminalPresentation implements Presentation {
  readonly interactive: boolean;
  private readonly input: Readable;
  private readonly output: Writable;

  constructor(options: {
    input: Readable;
    output: Writable;
    interactive: boolean;
  }) {
    this.interactive = options.interactive;
    this.input = options.input;
    this.output = options.output;
  }

  private requireInteractive(): void {
    if (!this.interactive) {
      throw new InteractiveInputUnavailableError();
    }
  }

  async text(request: TextRequest): Promise<string> {
    this.requireInteractive();
    const result = await clack.text({
      ...request,
      validate: (value) => request.validate(value ?? ""),
      input: this.input,
      output: this.output,
    });
    if (clack.isCancel(result)) {
      throw new CancelledError();
    }
    return result;
  }

  async password(request: Omit<TextRequest, "initialValue">): Promise<string> {
    this.requireInteractive();
    const result = await clack.password({
      ...request,
      validate: (value) => request.validate(value ?? ""),
      input: this.input,
      output: this.output,
    });
    if (clack.isCancel(result)) {
      throw new CancelledError();
    }
    return result;
  }

  async confirm(message: string): Promise<boolean> {
    this.requireInteractive();
    const result = await clack.confirm({
      message,
      initialValue: false,
      input: this.input,
      output: this.output,
    });
    if (clack.isCancel(result)) {
      throw new CancelledError();
    }
    return result;
  }

  intro(message: string): void {
    if (this.interactive) {
      clack.intro(message, { output: this.output });
    }
  }

  info(message: string): void {
    if (this.interactive) {
      clack.log.info(message, { output: this.output });
      return;
    }
    this.output.write(`${message}\n`);
  }

  success(message: string): void {
    if (this.interactive) {
      clack.log.success(message, { output: this.output });
      return;
    }
    this.output.write(`${message}\n`);
  }

  outro(message: string): void {
    if (this.interactive) {
      clack.outro(message, { output: this.output });
    }
  }

  error(message: string): void {
    if (this.interactive) {
      clack.log.error(message, { output: this.output });
      return;
    }
    this.output.write(`Error: ${message}\n`);
  }

  cancel(message: string): void {
    if (this.interactive) {
      clack.cancel(message, { output: this.output });
      return;
    }
    this.output.write(`${message}\n`);
  }

  async progress<T>(message: string, operation: () => Promise<T>): Promise<T> {
    if (!this.interactive) {
      return await operation();
    }
    const progress = clack.spinner({
      output: this.output,
      cancelMessage: "Finishing the current operation.",
    });
    progress.start(message);
    try {
      return await operation();
    } finally {
      progress.clear();
    }
  }
}
