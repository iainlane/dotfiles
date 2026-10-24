import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import type { PlanFiles } from "./files.ts";

export interface PlanRevision {
  path: string;
  content: string;
  revision: string;
}

function digest(content: string): string {
  return createHash("sha256").update(content).digest("hex");
}

export class PlanStore {
  readonly path: string;
  private readonly directory: string;

  constructor(
    directory: string,
    sessionId: string,
    private readonly files: PlanFiles,
  ) {
    this.directory = files.ensureDirectory(directory);
    this.path = join(this.directory, `${digest(sessionId)}.md`);
  }

  permitsWrite(path: string, cwd: string): boolean {
    const candidate = resolve(cwd, path);
    if (candidate !== this.path) {
      return false;
    }

    try {
      if (this.files.canonical(dirname(candidate)) !== this.directory) {
        return false;
      }
      const kind = this.files.kind(candidate);
      return kind === "missing" || kind === "file";
    } catch {
      return false;
    }
  }

  read(): PlanRevision {
    if (!this.permitsWrite(this.path, this.directory)) {
      throw new Error(
        "The active plan must be a regular file in the plans directory.",
      );
    }

    const content = this.files.read(this.path);
    if (content === undefined) {
      throw new Error(
        `The active plan is missing. Write a new implementation plan to ${this.path} before requesting approval.`,
      );
    }
    return { path: this.path, content, revision: digest(content) };
  }

  exists(): boolean {
    return this.files.kind(this.path) !== "missing";
  }

  write(content: string): PlanRevision {
    if (!this.permitsWrite(this.path, this.directory)) {
      throw new Error(
        "Cannot replace a plan through a symlink or an unexpected path.",
      );
    }
    this.files.replace(this.path, content);

    return this.read();
  }

  matches(presented: PlanRevision): boolean {
    try {
      const current = this.read();
      return (
        presented.path === current.path &&
        presented.revision === current.revision
      );
    } catch {
      return false;
    }
  }
}
