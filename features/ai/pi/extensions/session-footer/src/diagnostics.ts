import { Type } from "typebox";
import { Check } from "typebox/value";
import { text } from "./text.ts";

export interface FileDiagnostics {
  errors: number;
  warnings: number;
  pending: boolean;
  truncated: boolean;
  messages: string[];
}

const snapshotSchema = Type.Object({
  v: Type.Literal(1),
  cwd: Type.String(),
  seq: Type.Number({ minimum: 0 }),
  files: Type.Array(Type.Unknown()),
});
const fileSchema = Type.Object({
  path: Type.String(),
  diagnostics: Type.Array(Type.Unknown()),
  truncated: Type.Optional(Type.Boolean()),
});
const diagnosticSchema = Type.Object({
  severity: Type.String(),
  message: Type.Optional(Type.Unknown()),
});
const touchedSchema = Type.Object({
  v: Type.Literal(1),
  cwd: Type.String(),
  paths: Type.Array(Type.Unknown()),
});
const pathSchema = Type.String();

export class Diagnostics {
  readonly files = new Map<string, FileDiagnostics>();
  private sequence = -1;

  constructor(private readonly cwd: string) {}

  receive(raw: unknown): void {
    if (
      !Check(snapshotSchema, raw) ||
      raw.cwd !== this.cwd ||
      raw.seq <= this.sequence
    ) {
      return;
    }
    const seq = raw.seq;
    this.sequence = seq;

    for (const file of raw.files) {
      if (!Check(fileSchema, file)) {
        continue;
      }
      const items = file.diagnostics.filter((item) =>
        Check(diagnosticSchema, item),
      );

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
    if (!Check(touchedSchema, raw) || raw.cwd !== this.cwd) {
      return;
    }

    for (const value of raw.paths) {
      if (!Check(pathSchema, value)) {
        continue;
      }

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
