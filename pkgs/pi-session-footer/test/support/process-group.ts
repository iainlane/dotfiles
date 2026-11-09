export class ProcessGroup {
  private readonly pid: number;

  constructor(pid: number) {
    if (!Number.isInteger(pid) || pid <= 0) {
      throw new RangeError("Expected a positive process-group ID");
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

  private exitedWithin(milliseconds: number): Promise<boolean> {
    const deadline = performance.now() + milliseconds;
    return new Promise((resolve, reject) => {
      const timer = setInterval(() => {
        try {
          const alive = this.signal(0);
          if (alive && performance.now() < deadline) {
            return;
          }
          clearInterval(timer);
          resolve(!alive);
        } catch (error) {
          clearInterval(timer);
          reject(
            new Error(`Cannot inspect process group ${this.pid}`, {
              cause: error,
            }),
          );
        }
      }, 25);
    });
  }

  async close(): Promise<void> {
    if (!this.signal("SIGTERM") || (await this.exitedWithin(3000))) {
      return;
    }
    this.signal("SIGKILL");
    if (!(await this.exitedWithin(3000))) {
      throw new Error(`Process group ${this.pid} did not exit after SIGKILL`);
    }
  }
}
