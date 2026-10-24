import { randomUUID } from "node:crypto";
import {
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import type { PlanFiles } from "./files.ts";

export const nodeFiles: PlanFiles = {
  ensureDirectory(path) {
    mkdirSync(path, { recursive: true, mode: 0o700 });
    return realpathSync(path);
  },
  canonical: realpathSync,
  kind(path) {
    const stat = lstatSync(path, { throwIfNoEntry: false });
    if (!stat) {
      return "missing";
    }
    if (stat.isSymbolicLink()) {
      return "symlink";
    }
    return stat.isFile() ? "file" : "other";
  },
  read(path): string | undefined {
    let content: string | undefined;
    try {
      content = readFileSync(path, "utf8");
    } catch (error) {
      if (
        !(error instanceof Error && "code" in error && error.code === "ENOENT")
      ) {
        throw error;
      }
    }
    return content;
  },
  replace(path, content) {
    const temporary = `${path}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporary, content, {
        encoding: "utf8",
        mode: 0o600,
        flag: "wx",
      });
      renameSync(temporary, path);
    } finally {
      rmSync(temporary, { force: true });
    }
  },
};
