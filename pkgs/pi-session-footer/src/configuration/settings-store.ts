import type { LoadedSettings, PresentationDocument } from "./settings.ts";

export type SaveDestination =
  | { kind: "session" }
  | { kind: "file"; path: string; newUserFile: boolean; repair: boolean }
  | { kind: "unavailable"; path: string; problem: SettingsStoreError };

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

export abstract class SettingsStoreError extends Error {
  protected constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = new.target.name;
  }
}

export class IrregularSettingsFileError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string) {
    super("Expected a regular settings file");
    this.path = path;
  }
}

export class SymlinkSettingsFileError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string) {
    super("Cannot save to a symbolic link");
    this.path = path;
  }
}

export class ReadOnlySettingsFileError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string) {
    super("The settings file is not writable");
    this.path = path;
  }
}

export class ReadOnlySettingsDirectoryError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string) {
    super("The settings directory is not writable");
    this.path = path;
  }
}

export class SettingsReadError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string, options: ErrorOptions) {
    super(`Could not read ${path}`, options);
    this.path = path;
  }
}

/** The settings files changed after the snapshot that a save started from. */
export class SettingsConflictError extends SettingsStoreError {
  constructor() {
    super("Settings changed on disk. Reopen the editor before saving");
  }
}

export class SessionOnlySettingsError extends SettingsStoreError {
  constructor() {
    super("This profile uses session-only changes");
  }
}

export class SettingsDestinationChangedError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string) {
    super("The settings destination changed");
    this.path = path;
  }
}

export class UnconfirmedCreateError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string) {
    super("Confirm creating user settings");
    this.path = path;
  }
}

export class UnconfirmedRepairError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string) {
    super("Confirm replacing invalid settings");
    this.path = path;
  }
}

export class UnconfirmedRemoveError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string) {
    super("Confirm removing user settings");
    this.path = path;
  }
}

function failure(error: unknown): string {
  return error instanceof Error &&
    "code" in error &&
    typeof error.code === "string"
    ? error.code
    : "I/O error";
}

export class SettingsWriteError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string, options: { cause: unknown }) {
    super(`Could not save ${path}: ${failure(options.cause)}`, options);
    this.path = path;
  }
}

export class SettingsRemoveError extends SettingsStoreError {
  readonly path: string;

  constructor(path: string, options: { cause: unknown }) {
    super(`Could not remove ${path}: ${failure(options.cause)}`, options);
    this.path = path;
  }
}
