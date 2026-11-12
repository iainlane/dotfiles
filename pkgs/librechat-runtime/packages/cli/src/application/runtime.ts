import { readFile } from "node:fs/promises";
import {
  configureSync,
  disposeSync,
  getLogger,
  type Logger,
} from "@logtape/logtape";
import { diagnosticSink } from "@dotfiles/librechat-runtime/logging";
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

function environmentSecrets(
  environment: Record<string, string | undefined>,
): string[] {
  return Object.entries(environment)
    .filter(([key]) =>
      /password|secret|token|api[_-]?key|private[_-]?key/iu.test(key),
    )
    .flatMap(([, value]) =>
      value === undefined || value.length === 0 ? [] : [value],
    );
}

export class RuntimeErrorPolicy {
  private readonly commands: ErrorReporter;
  private readonly services: ErrorReporter;

  constructor(
    environment: Record<string, string | undefined>,
    write: (text: string) => void,
    logger: Logger,
  ) {
    const secrets = environmentSecrets(environment);
    this.commands = new ErrorReporter({
      diagnostics: environment.LIBRECHAT_DIAGNOSTICS === "1",
      write,
      logger,
      secrets,
    });
    this.services = new ErrorReporter({
      diagnostics: true,
      write,
      logger,
      secrets,
    });
  }

  report(error: unknown): void {
    this.commands.report(error);
  }

  diagnose(error: unknown, service: boolean, logger: Logger): void {
    (service ? this.services : this.commands).diagnose(error, logger);
  }
}

function writeOutput(text: string): void {
  process.stdout.write(text);
}

export async function main(
  args: string[],
  entry: EntryPoint = "runtime",
): Promise<void> {
  const secrets = environmentSecrets(process.env);
  configureSync({
    sinks: {
      stderr: diagnosticSink({
        write: writeError,
        terminal: process.stderr.isTTY,
        secrets,
      }),
    },
    loggers: [
      { category: ["librechat"], lowestLevel: "info", sinks: ["stderr"] },
      {
        category: ["logtape", "meta"],
        lowestLevel: "warning",
        sinks: ["stderr"],
      },
    ],
  });
  const logger = getLogger(["librechat"]).with({ entryPoint: entry });
  const errors = new RuntimeErrorPolicy(process.env, writeError, logger);
  try {
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
      secrets,
      writeOutput,
    });
    const result = await runCommand(args, entry, {
      logger,
      manifest: process.env.LIBRECHAT_INTERNAL_MANIFEST,
      files,
      services,
      presentation,
      writeOutput,
      reportDiagnostics: (error, service, commandLogger) =>
        errors.diagnose(error, service, commandLogger),
      openDeployment: async (file) =>
        await openDeployment(file, files, globalThis.fetch),
    });

    if (result.forceExit) {
      await exitAfterFlushing(result.status);
    }
    process.exitCode = result.status;
  } catch (error) {
    errors.report(error);
    process.exitCode = 1;
  } finally {
    disposeSync();
  }
}
