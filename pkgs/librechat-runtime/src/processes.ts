import { execFile, spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { promisify } from "node:util";
import { setTimeout as delay } from "node:timers/promises";

export interface Command {
  executable: string;
  args: string[];
  environment?: Record<string, string>;
  directory?: string;
  uid?: number;
  gid?: number;
}

export interface ManagedProcess {
  exited: Promise<void>;

  running(): boolean;

  stop(): Promise<void>;
}

export interface ProcessRunner {
  run(command: Command): Promise<string>;

  start(command: Command): Promise<ManagedProcess>;
}

export class CommandExecutionError extends Error {
  readonly executable: string;
  readonly exitCode: number | undefined;

  constructor(command: Command, cause: unknown) {
    super(`Command failed: ${command.executable}`, { cause });

    this.name = "CommandExecutionError";

    this.executable = command.executable;

    this.exitCode =
      typeof cause === "object" &&
      cause !== null &&
      "code" in cause &&
      typeof cause.code === "number"
        ? cause.code
        : undefined;
  }
}

export class ProcessStartError extends Error {
  readonly executable: string;

  constructor(command: Command, cause: unknown) {
    super(`Cannot start process: ${command.executable}`, { cause });

    this.name = "ProcessStartError";

    this.executable = command.executable;
  }
}

export class ProcessExitError extends Error {
  readonly executable: string;
  readonly code: number | null;

  constructor(command: Command, code: number | null) {
    super(`Service exited: ${command.executable}`);

    this.name = "ProcessExitError";

    this.executable = command.executable;

    this.code = code;
  }
}

const execute = promisify(execFile);

class NodeManagedProcess implements ManagedProcess {
  private readonly outcome: Promise<Error | undefined>;
  private readonly child: ChildProcess;
  private readonly command: Command;
  private stopped = false;

  constructor(child: ChildProcess, command: Command) {
    this.child = child;

    this.command = command;

    this.outcome = new Promise<Error | undefined>((resolve) => {
      child.once("exit", (code) => {
        if (!this.stopped) {
          resolve(new ProcessExitError(this.command, code));

          return;
        }

        resolve(undefined);
      });

      child.once("error", (cause: unknown) => {
        resolve(new ProcessStartError(command, cause));
      });
    });
  }

  get exited(): Promise<void> {
    return this.waitForExit();
  }

  private async waitForExit(): Promise<void> {
    const error = await this.outcome;

    if (error !== undefined) {
      throw error;
    }
  }

  running(): boolean {
    return this.child.exitCode === null && this.child.signalCode === null;
  }

  async stop(): Promise<void> {
    this.stopped = true;

    if (!this.running()) {
      return;
    }

    this.child.kill("SIGTERM");

    await Promise.race([this.exited, delay(5000, undefined, { ref: false })]);

    if (this.running()) {
      this.child.kill("SIGKILL");
    }

    await this.exited;
  }
}

export class NodeProcessRunner implements ProcessRunner {
  private readonly environment: Record<string, string>;

  constructor(environment: Record<string, string>) {
    this.environment = environment;
  }

  async run(command: Command): Promise<string> {
    try {
      const result = await execute(command.executable, command.args, {
        env: { ...this.environment, ...command.environment },
        cwd: command.directory,
        uid: command.uid,
        gid: command.gid,
        timeout: 120_000,
        maxBuffer: 1024 * 1024,
      });

      return result.stdout;
    } catch (cause) {
      throw new CommandExecutionError(command, cause);
    }
  }

  async start(command: Command): Promise<ManagedProcess> {
    const child = spawn(command.executable, command.args, {
      env: { ...this.environment, ...command.environment },
      cwd: command.directory,
      uid: command.uid,
      gid: command.gid,
      stdio: ["ignore", "inherit", "inherit"],
    });

    const managed = new NodeManagedProcess(child, command);

    try {
      await once(child, "spawn");

      return managed;
    } catch (cause) {
      throw new ProcessStartError(command, cause);
    }
  }
}
