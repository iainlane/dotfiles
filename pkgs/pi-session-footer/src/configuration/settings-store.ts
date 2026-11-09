import type { LoadedSettings, PresentationDocument } from "./settings.ts";

export type SaveDestination =
  | { kind: "session" }
  | { kind: "file"; path: string; newUserFile: boolean; repair: boolean }
  | { kind: "unavailable"; path: string; reason: string };

export interface SettingsSnapshot {
  loaded: LoadedSettings;
  base: LoadedSettings;
  userPath: string;
  userExists: boolean;
  revision: string;
  destination: SaveDestination;
}

export type SettingsChange =
  | { kind: "write"; document: PresentationDocument; confirmed?: boolean }
  | { kind: "reset"; confirmed?: boolean };

export interface SettingsStore {
  load(): SettingsSnapshot;
  save(expected: SettingsSnapshot, change: SettingsChange): SettingsSnapshot;
}

export class SettingsStoreError extends Error {
  constructor(
    readonly kind:
      | "session"
      | "unavailable"
      | "conflict"
      | "confirmation"
      | "io",
    message: string,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = "SettingsStoreError";
  }
}
