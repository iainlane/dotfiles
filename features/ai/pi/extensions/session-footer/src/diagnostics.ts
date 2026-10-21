import { finite, record, text } from "./text.ts";

export interface FileDiagnostics {
  errors: number;
  warnings: number;
  pending: boolean;
  truncated: boolean;
  messages: string[];
}

export class Diagnostics {
  readonly files = new Map<string, FileDiagnostics>();
  private sequence = -1;

  constructor(private readonly cwd: string) {}

  receive(raw: unknown): void {
    if (
      !record(raw) ||
      raw.v !== 1 ||
      raw.cwd !== this.cwd ||
      !Array.isArray(raw.files)
    )
      return;

    const seq = finite(raw.seq);

    if (seq === undefined || seq <= this.sequence) return;

    this.sequence = seq;

    for (const file of raw.files) {
      if (
        !record(file) ||
        typeof file.path !== "string" ||
        !Array.isArray(file.diagnostics)
      )
        continue;

      const items = file.diagnostics.filter(record);

      this.files.set(file.path, {
        errors: items.filter((item) => item.severity === "error").length,
        warnings: items.filter((item) => item.severity === "warning").length,
        pending: false,
        truncated: file.truncated === true,
        messages: items.map((item) => text(item.message, 300)),
      });
    }
  }

  touch(raw: unknown): void {
    if (
      !record(raw) ||
      raw.v !== 1 ||
      raw.cwd !== this.cwd ||
      !Array.isArray(raw.paths)
    )
      return;

    for (const value of raw.paths) {
      if (typeof value !== "string") continue;

      const path = value;
      const previous = this.files.get(path);

      this.files.set(path, {
        errors: 0,
        warnings: 0,
        truncated: false,
        messages: [],
        ...previous,
        pending: true,
      });
    }
  }

  summary() {
    const values = [...this.files.values()];

    return {
      errors: values.reduce((sum, file) => sum + file.errors, 0),
      warnings: values.reduce((sum, file) => sum + file.warnings, 0),
      pending: values.filter((file) => file.pending).length,
      truncated: values.some((file) => file.truncated),
      observed: this.sequence >= 0,
    };
  }
}
