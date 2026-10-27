import {
  CommandExecutionError,
  type ManagedProcess,
  type ProcessRunner,
} from "./processes.ts";

const unitNotInstalledExitCode = 5;

interface SystemdServiceOptions {
  systemctl: string;
  unit: string;
}

export class SystemdService {
  private readonly options: SystemdServiceOptions;
  private readonly processes: Pick<ProcessRunner, "run">;

  constructor(
    options: SystemdServiceOptions,
    processes: Pick<ProcessRunner, "run">,
  ) {
    this.options = options;

    this.processes = processes;
  }

  async stop(child: ManagedProcess): Promise<void> {
    try {
      await this.processes.run({
        executable: this.options.systemctl,
        args: ["stop", this.options.unit],
      });
    } catch (error) {
      if (
        !(error instanceof CommandExecutionError) ||
        error.exitCode !== unitNotInstalledExitCode
      ) {
        throw error;
      }
    }

    await child.stop();
  }
}
