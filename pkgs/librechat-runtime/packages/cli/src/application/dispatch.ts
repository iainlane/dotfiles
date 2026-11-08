import {
  CancelledError,
  OperationalError,
  UsageError,
} from "#cli/application/errors";
import {
  requireBootstrapOptions,
  resolveBootstrapInputs,
  resolveWorkspaceInput,
} from "#cli/application/inputs";
import type { CommandDependencies } from "#cli/application/ports";
import {
  parseCommand,
  type CommandIntent,
  type EntryPoint,
} from "#cli/definitions/commands";

export interface CommandResult {
  status: number;
  forceExit: boolean;
}

function deploymentFile(
  manifest: string | undefined,
  dependencies: CommandDependencies,
): string {
  const file = manifest ?? dependencies.manifest;
  if (file === undefined) {
    throw new OperationalError(
      "No LibreChat deployment is configured. Use the librechatctl installed by Home Manager.",
    );
  }
  return file;
}

async function execute(
  intent: CommandIntent,
  entry: EntryPoint,
  dependencies: CommandDependencies,
): Promise<void> {
  const { presentation, services } = dependencies;
  switch (intent.kind) {
    case "help":
    case "version":
      dependencies.writeOutput(`${intent.text}\n`);
      return;
    case "bootstrap": {
      requireBootstrapOptions(intent, presentation);
      presentation.intro("LibreChat bootstrap");
      const deployment = await dependencies.openDeployment(
        deploymentFile(intent.manifest, dependencies),
      );
      const { input, existing } = await resolveBootstrapInputs(intent, {
        accounts: deployment.accounts,
        files: dependencies.files,
        prompts: presentation,
      });
      await presentation.progress(
        "Provisioning your account and personal agents",
        () => deployment.accounts.bootstrap(input),
      );
      if (presentation.interactive) {
        presentation.success(
          existing
            ? "Display name and personal agents updated."
            : "Administrator and personal agents created.",
        );
        if (existing) {
          presentation.info("The existing password was preserved.");
        }
        presentation.outro(
          existing
            ? "Bootstrap completed."
            : `Open ${deployment.url} and sign in.`,
        );
        return;
      }
      dependencies.writeOutput("LibreChat account bootstrap completed.\n");
      return;
    }
    case "reset": {
      presentation.intro("Reset conversation workspace");
      const conversation = await resolveWorkspaceInput(intent, presentation);
      const deployment = await dependencies.openDeployment(
        deploymentFile(intent.manifest, dependencies),
      );
      await presentation.progress("Deleting the conversation workspace", () =>
        deployment.resetWorkspace(conversation),
      );
      if (entry === "runtime") {
        return;
      }
      if (presentation.interactive) {
        presentation.outro(
          "Workspace deleted. The next workspace operation creates a fresh workspace.",
        );
        return;
      }
      dependencies.writeOutput("Workspace deleted.\n");
      return;
    }
    case "serve":
      await services.serve(intent.file);
      return;
    case "guest":
      await services.guest(intent.file);
      return;
    case "hook":
      await services.hook(intent.file);
      return;
    case "archive":
      dependencies.writeOutput(await services.archive(intent.query));
  }
}

export async function runCommand(
  args: string[],
  entry: EntryPoint,
  dependencies: CommandDependencies,
): Promise<CommandResult> {
  let forceExit = false;
  let failure = "LibreChat command failed. Check the service logs.";
  try {
    const intent = parseCommand(args, entry);
    forceExit = intent.kind === "bootstrap";
    if (intent.kind === "bootstrap") {
      failure =
        "Could not bootstrap LibreChat. Check that the LibreChat services are running and consult their logs.";
    }
    await execute(intent, entry, dependencies);
    return { status: 0, forceExit };
  } catch (error) {
    if (error instanceof CancelledError) {
      dependencies.presentation.cancel(error.message);
      return { status: error.status, forceExit };
    }
    if (error instanceof UsageError || error instanceof OperationalError) {
      dependencies.presentation.error(error.message);
      return { status: error.status, forceExit };
    }
    dependencies.presentation.error(failure);
    return { status: 1, forceExit };
  }
}
