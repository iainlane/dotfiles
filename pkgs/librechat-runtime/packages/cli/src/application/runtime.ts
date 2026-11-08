import { readFile } from "node:fs/promises";
import { OperationalError, UsageError } from "#cli/application/errors";
import { runCommand } from "#cli/application/dispatch";
import { interactiveMode } from "#cli/application/inputs";
import { openDeployment } from "#cli/adapters/deployment";
import { NativeRuntimeServices } from "#cli/adapters/services";
import type { EntryPoint } from "#cli/definitions/commands";
import { exitAfterFlushing } from "#cli/presentation/output";
import { TerminalPresentation } from "#cli/presentation/terminal";

export function logError(error: unknown): void {
  const message =
    error instanceof OperationalError || error instanceof UsageError
      ? error.message
      : "LibreChat command failed. Check the service logs.";
  process.stderr.write(`Error: ${message}\n`);
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
  const services = new NativeRuntimeServices({
    files,
    http: globalThis.fetch,
    input: process.stdin,
    brokerToken: process.env.AGENTSVIEW_BROKER_TOKEN,
    writeOutput,
    reportError: logError,
  });
  const result = await runCommand(args, entry, {
    manifest: process.env.LIBRECHAT_INTERNAL_MANIFEST,
    files,
    services,
    presentation,
    writeOutput,
    openDeployment: async (file) =>
      await openDeployment(file, files, globalThis.fetch),
  });

  if (result.forceExit) {
    await exitAfterFlushing(result.status);
  }
  process.exitCode = result.status;
}
