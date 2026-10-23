import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import xterm from "@xterm/headless";
import { visibleWidth } from "@earendil-works/pi-tui";
import { record } from "../../src/text.ts";

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
  private readonly process: ChildProcessWithoutNullStreams;
  private readonly closed = Promise.withResolvers<void>();
  private writes = Promise.resolve();
  private failure: string | undefined;
  private closing = false;
  private output = "";
  private code: number | undefined;
  private stderr = "";

  constructor(configuration: Configuration) {
    this.process = spawn("python3", [
      fileURLToPath(new URL("./bridge.py", import.meta.url)),
    ]);

    this.process.on("error", (error) => {
      this.failure = error.message;
    });
    this.process.on("close", () => {
      if (this.code === undefined && !this.closing)
        this.failure = `PTY bridge exited before Pi: ${this.stderr}`;

      this.closed.resolve();
    });
    this.process.stdin.on("error", (error) => {
      if (!this.closing) this.failure = error.message;
    });
    this.process.stderr.on("data", (data: Buffer) => {
      this.stderr += data.toString();
    });
    this.terminal.onData((data) => this.input(data));

    const lines = createInterface({ input: this.process.stdout });

    lines.on("line", (line) => {
      const message: unknown = JSON.parse(line);

      if (!record(message)) {
        this.failure = "Invalid PTY bridge message";

        return;
      }

      if (message.type === "exit" && typeof message.code === "number")
        this.code = message.code;

      if (message.type !== "data" || typeof message.data !== "string") return;

      const data = Buffer.from(message.data, "base64");

      this.output += data.toString();
      this.writes = this.writes.then(
        () =>
          new Promise<void>((resolve) => this.terminal.write(data, resolve)),
      );
    });

    this.send(configuration);
  }

  private send(message: object): void {
    if (!this.process.stdin.destroyed)
      this.process.stdin.write(JSON.stringify(message) + "\n");
  }

  input(value: string): void {
    this.send({ type: "input", data: Buffer.from(value).toString("base64") });
  }

  resize(columns: number, rows = 24): void {
    this.terminal.resize(columns, rows);
    this.send({ type: "resize", columns, rows });
  }

  async screen(): Promise<string[]> {
    await this.writes;

    if (this.failure) throw new Error(this.failure);

    if (this.code !== undefined && !this.closing)
      throw new Error(
        `Pi exited with ${this.code}: ${this.stderr}\n${this.output.slice(-12000)}`,
      );

    const buffer = this.terminal.buffer.active;

    return Array.from(
      { length: this.terminal.rows },
      (_, row) =>
        buffer.getLine(buffer.viewportY + row)?.translateToString(true) ?? "",
    );
  }

  diagnostics(): string {
    return `${this.stderr}\n${this.output.slice(-12000)}`;
  }

  color(value?: string): number | undefined {
    return this.style(value)?.color;
  }

  style(value?: string): { color: number; bold: boolean } | undefined {
    const buffer = this.terminal.buffer.active;
    const first = buffer.viewportY + this.terminal.rows - 2;

    for (let row = first; row < first + 2; row++) {
      const line = buffer.getLine(row);

      if (!line) continue;

      const text = line.translateToString(true);
      const index = value === undefined ? 0 : text.indexOf(value);

      if (index < 0) continue;

      const cell = line.getCell(visibleWidth(text.slice(0, index)));

      if (!cell) return undefined;

      return { color: cell.getFgColor(), bold: Boolean(cell.isBold()) };
    }

    return undefined;
  }

  async close(): Promise<void> {
    this.closing = true;

    if (this.code === undefined) this.send({ type: "stop" });

    const deadline = setTimeout(() => this.process.kill("SIGKILL"), 5000);

    try {
      await this.closed.promise;
      await this.writes;
    } finally {
      clearTimeout(deadline);
      this.terminal.dispose();
    }
  }
}
