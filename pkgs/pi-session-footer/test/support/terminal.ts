import { spawn, type IPty } from "@homebridge/node-pty-prebuilt-multiarch";
import { watch } from "node:fs";
import { dirname } from "node:path";
import { onTestFinished } from "vitest";
import xterm from "@xterm/headless";
import { visibleWidth } from "@earendil-works/pi-tui";
import { ProcessGroup } from "./process-group.ts";

interface Configuration {
  command: string[];
  cwd: string;
  env: Record<string, string>;
  columns: number;
  rows: number;
}

export class PiTerminal {
  readonly terminal = new xterm.Terminal({
    cols: 220,
    rows: 24,
    allowProposedApi: true,
  });
  private readonly process: IPty;
  private readonly group: ProcessGroup;
  private stopping: Promise<void> | undefined;
  private readonly closed = Promise.withResolvers<void>();
  private writes = Promise.resolve();
  private closing = false;
  private output = "";
  private code: number | undefined;
  private readonly changes = new Set<() => void>();
  private readonly waits = new Set<() => void>();

  constructor(configuration: Configuration) {
    const [file, ...args] = configuration.command;
    if (file === undefined) {
      throw new Error("Expected a PTY command");
    }
    try {
      this.process = spawn(file, args, {
        name: "xterm-256color",
        cwd: configuration.cwd,
        env: configuration.env,
        cols: configuration.columns,
        rows: configuration.rows,
      });
    } catch (error) {
      this.terminal.dispose();
      throw error;
    }
    this.group = new ProcessGroup(this.process.pid);
    this.process.onExit(({ exitCode }) => {
      this.code = exitCode;
      this.closed.resolve();
      this.notify();
    });
    this.terminal.onData((data) => this.input(data));
    this.process.onData((data) => {
      this.output += data;
      this.writes = this.writes.then(
        () =>
          new Promise<void>((resolve) => {
            this.terminal.write(data, () => {
              resolve();
              this.notify();
            });
          }),
      );
    });
    onTestFinished(async ({ task }) => {
      if (task.result?.state === "fail") {
        console.error(await this.report());
      }
      await this.close();
    });
  }

  private async report(): Promise<string> {
    const screen = await this.screen().catch(() => []);
    return `${screen.join("\n")}\n${this.diagnostics()}`;
  }

  private notify(): void {
    for (const change of this.changes) {
      change();
    }
  }

  /**
   * Resolves once `check` passes. `check` runs against the screen now, after
   * each write of Pi's output to the terminal, and after each change in the
   * directories of the `watched` files. When the PTY process exits or the
   * terminal closes first, the wait rejects with the last failure of `check`.
   */
  until(
    check: (screen: string[]) => void | Promise<void>,
    watched: string[] = [],
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      let done = false;
      let running = false;
      let again = false;
      let lastFailure: unknown;
      const watchers = [...new Set(watched.map((path) => dirname(path)))].map(
        (directory) => watch(directory, () => schedule()),
      );
      const finish = (error?: Error) => {
        if (done) {
          return;
        }

        done = true;
        this.changes.delete(schedule);
        this.waits.delete(cancel);
        for (const watcher of watchers) {
          watcher.close();
        }
        if (error === undefined) {
          resolve();
        } else {
          reject(error);
        }
      };
      const attempt = async () => {
        let screen: string[];
        try {
          screen = await this.screen();
        } catch (error) {
          finish(
            new Error(
              `${String(error)}\nLast check failure: ${String(lastFailure)}`,
            ),
          );
          return;
        }
        try {
          await check(screen);
          finish();
        } catch (error) {
          lastFailure = error;
        }
      };
      const schedule = (): void => {
        if (done) {
          return;
        }
        if (running) {
          again = true;
          return;
        }
        running = true;
        const after = () => {
          running = false;
          if (again) {
            again = false;
            schedule();
          }
        };
        attempt().then(after, after);
      };
      const cancel = () =>
        finish(
          new Error("The terminal closed before the check passed", {
            cause: lastFailure,
          }),
        );
      this.changes.add(schedule);
      this.waits.add(cancel);
      if (this.closing) {
        cancel();
        return;
      }
      schedule();
    });
  }

  input(value: string): void {
    if (this.code === undefined && !this.closing) {
      this.process.write(value);
    }
  }

  resize(columns: number, rows = 24): void {
    this.terminal.resize(columns, rows);
    if (this.code === undefined && !this.closing) {
      this.process.resize(columns, rows);
    }
  }

  async screen(): Promise<string[]> {
    await this.writes;

    if (this.code !== undefined && !this.closing) {
      throw new Error(
        `PTY process exited with ${this.code}:\n${this.output.slice(-12000)}`,
      );
    }

    const buffer = this.terminal.buffer.active;

    return Array.from(
      { length: this.terminal.rows },
      (_, row) =>
        buffer.getLine(buffer.viewportY + row)?.translateToString(true) ?? "",
    );
  }

  diagnostics(): string {
    return this.output.slice(-12000);
  }

  color(value?: string): number | undefined {
    return this.style(value)?.color;
  }

  style(value?: string): { color: number; bold: boolean } | undefined {
    const buffer = this.terminal.buffer.active;
    const last = buffer.viewportY + this.terminal.rows - 1;

    for (let row = last; row >= buffer.viewportY; row--) {
      const line = buffer.getLine(row);

      if (!line) {
        continue;
      }

      const text = line.translateToString(true);
      const index = value === undefined ? 0 : text.indexOf(value);

      if (index < 0) {
        continue;
      }

      const cell = line.getCell(visibleWidth(text.slice(0, index)));

      if (!cell) {
        return undefined;
      }

      return { color: cell.getFgColor(), bold: Boolean(cell.isBold()) };
    }

    return undefined;
  }

  close(): Promise<void> {
    this.closing = true;
    for (const cancel of this.waits) {
      cancel();
    }
    this.stopping ??= this.stop();
    return this.stopping;
  }

  private async stop(): Promise<void> {
    try {
      await this.group.close();
      await this.closed.promise;
      await this.writes;
    } finally {
      this.terminal.dispose();
    }
  }
}
