import { OperationalError, UsageError } from "#cli/application/errors";
import { errorDiagnostic } from "@dotfiles/librechat-runtime/diagnostics";

interface ErrorOutput {
  diagnostics: boolean;
  write(text: string): void;
}

export class ErrorReporter {
  private readonly output: ErrorOutput;

  constructor(output: ErrorOutput) {
    this.output = output;
  }

  report(error: unknown): void {
    const message =
      error instanceof OperationalError || error instanceof UsageError
        ? error.message
        : "LibreChat command failed. Check the service logs.";
    this.output.write(`Error: ${message}\n`);
    this.diagnose(error);
  }

  diagnose(error: unknown): void {
    if (this.output.diagnostics) {
      this.output.write(
        `${JSON.stringify({ event: "librechat-service-error", error: errorDiagnostic(error) })}\n`,
      );
    }
  }
}
