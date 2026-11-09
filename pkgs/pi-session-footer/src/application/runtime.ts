import type { GitState } from "#footer/integrations/git.ts";
import type { SettingsStore } from "#footer/configuration/settings-store.ts";

export interface Clock {
  now(): number;
  after(milliseconds: number, callback: () => void): () => void;
  every(milliseconds: number, callback: () => void): () => void;
}

export interface FooterRuntime {
  clock: Clock;
  homeDirectory: string;
  settingsPath: string;
  settingsStore: SettingsStore;
  requestId(): string;
  readGit(cwd: string, now: number): Promise<GitState | undefined>;
  reportError: (error: unknown) => void;
}
