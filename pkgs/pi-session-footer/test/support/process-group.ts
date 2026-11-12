import { setInterval } from "node:timers/promises";

/**
 * Resolves once `alive` returns false. Node reports the exit of its own child
 * processes only, so this polls.
 */
export async function untilGone(alive: () => boolean): Promise<void> {
  if (!alive()) {
    return;
  }
  for await (const probe of setInterval(25, alive)) {
    if (!probe()) {
      return;
    }
  }
}

export class InvalidProcessGroupError extends Error {
  constructor(readonly pid: number) {
    super(`Expected a positive process-group ID, not ${pid}`);
    this.name = "InvalidProcessGroupError";
  }
}

export class ProcessGroupProbeError extends Error {
  constructor(
    readonly pid: number,
    options: { cause: unknown },
  ) {
    super(`Cannot inspect process group ${pid}`, options);
    this.name = "ProcessGroupProbeError";
  }
}

export class ProcessGroup {
  private readonly pid: number;

  constructor(pid: number) {
    if (!Number.isInteger(pid) || pid <= 0) {
      throw new InvalidProcessGroupError(pid);
    }
    this.pid = pid;
  }

  private signal(signal: NodeJS.Signals | 0): boolean {
    try {
      return process.kill(-this.pid, signal);
    } catch (error) {
      if (!(error instanceof Error && "code" in error)) {
        throw error;
      }
      if (error.code === "ESRCH") {
        return false;
      }
      if (signal === 0 && error.code === "EPERM") {
        return true;
      }
      throw error;
    }
  }

  async close(): Promise<void> {
    if (!this.signal("SIGKILL")) {
      return;
    }
    try {
      await untilGone(() => this.signal(0));
    } catch (error) {
      throw new ProcessGroupProbeError(this.pid, { cause: error });
    }
  }
}
