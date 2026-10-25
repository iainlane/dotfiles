import type { GitState } from "./git.ts";

export interface Clock {
  now(): number;
  after(milliseconds: number, callback: () => void): () => void;
  every(milliseconds: number, callback: () => void): () => void;
}

export interface FooterRuntime {
  clock: Clock;
  homeDirectory: string;
  requestId(): string;
  readGit(cwd: string, now: number): Promise<GitState | undefined>;
  reportError: (error: unknown) => void;
}
