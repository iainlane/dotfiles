import { readFile } from "node:fs/promises";
import { ErrorReporter } from "#cli/presentation/errors";
import { runCommand } from "#cli/application/dispatch";
import { interactiveMode } from "#cli/application/inputs";
import { openDeployment } from "#cli/adapters/deployment";
import { NativeRuntimeServices } from "#cli/adapters/services";
import type { EntryPoint } from "#cli/definitions/commands";
import { exitAfterFlushing } from "#cli/presentation/output";
import { TerminalPresentation } from "#cli/presentation/terminal";

function writeError(text: string): void {
  process.stderr.write(text);
}

export function logError(error: unknown): void {
  new ErrorReporter({
    diagnostics: process.env.LIBRECHAT_DIAGNOSTICS === "1",
    write: writeError,
  }).report(error);
}

export class RuntimeErrorPolicy {
  private readonly commands: ErrorReporter;
  private readonly services: ErrorReporter;

  constructor(
    environment: Record<string, string | undefined>,
    write: (text: string) => void,
  ) {
    this.commands = new ErrorReporter({
      diagnostics: environment.LIBRECHAT_DIAGNOSTICS === "1",
      write,
    });
    this.services = new ErrorReporter({ diagnostics: true, write });
  }

  reportService(error: unknown): void {
    this.services.report(error);
  }

  diagnose(error: unknown, service: boolean): void {
    (service ? this.services : this.commands).diagnose(error);
  }
}

function writeOutput(text: string): void {
  process.stdout.write(text);
}

export async function main(
  args: string[],
  entry: EntryPoint = "runtime",
): Promise<void> {
  const files = {
    readText: async (file: string): Promise<string> =>
      await readFile(file, "utf8"),
  };
  const presentation = new TerminalPresentation({
    input: process.stdin,
    output: process.stderr,
    interactive: interactiveMode({
      stdinTTY: process.stdin.isTTY,
      stderrTTY: process.stderr.isTTY,
      ci: process.env.CI,
    }),
  });
  const errors = new RuntimeErrorPolicy(process.env, writeError);
  const services = new NativeRuntimeServices({
    files,
    http: globalThis.fetch,
    input: process.stdin,
    brokerToken: process.env.AGENTSVIEW_BROKER_TOKEN,
    writeOutput,
    reportError: (error) => errors.reportService(error),
  });
  const result = await runCommand(args, entry, {
    manifest: process.env.LIBRECHAT_INTERNAL_MANIFEST,
    files,
    services,
    presentation,
    writeOutput,
    reportDiagnostics: (error, service) => errors.diagnose(error, service),
    openDeployment: async (file) =>
      await openDeployment(file, files, globalThis.fetch),
  });

  if (result.forceExit) {
    await exitAfterFlushing(result.status);
  }
  process.exitCode = result.status;
}
