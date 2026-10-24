export interface PlanFiles {
  ensureDirectory(path: string): string;
  canonical(path: string): string;
  kind(path: string): "file" | "symlink" | "other" | "missing";
  read(path: string): string | undefined;
  replace(path: string, content: string): void;
}
