import { resolve } from "node:path";
import type { PlanFiles } from "../src/files.ts";

export class MemoryFiles implements PlanFiles {
  readonly contents = new Map<string, string>();
  ensureDirectory = resolve;
  canonical = resolve;
  kind(path: string): "file" | "missing" {
    return this.contents.has(path) ? "file" : "missing";
  }
  read(path: string): string | undefined {
    return this.contents.get(path);
  }
  replace(path: string, content: string): void {
    this.contents.set(path, content);
  }
}
