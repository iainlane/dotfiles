import { resolve } from "node:path";
import type { PlanFiles } from "#planning/files.ts";

export class MemoryFiles implements PlanFiles {
  readonly contents = new Map<string, string>();
  readonly failures = new Map<string, Error>();
  directoryFailure: Error | undefined;
  canonical = resolve;
  ensureDirectory(path: string): string {
    if (this.directoryFailure) {
      throw this.directoryFailure;
    }
    return resolve(path);
  }
  kind(path: string): "file" | "missing" {
    this.access(path);
    return this.contents.has(path) ? "file" : "missing";
  }
  read(path: string): string | undefined {
    this.access(path);
    return this.contents.get(path);
  }
  replace(path: string, content: string): void {
    this.contents.set(path, content);
  }
  private access(path: string): void {
    const failure = this.failures.get(path);
    if (failure) {
      throw failure;
    }
  }
}
