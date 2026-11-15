import { setImmediate } from "node:timers/promises";
import type { Clock, FooterRuntime } from "#footer/application/runtime.ts";
import { dirname } from "node:path";
import { isDeepStrictEqual } from "node:util";
import {
  loadSettings,
  parsePresentationDocument,
  presentationDocument,
  resolveSettings,
  type LoadedSettings,
} from "#footer/configuration/settings.ts";
import { SettingsError } from "#footer/configuration/settings-errors.ts";
import {
  ReadOnlySettingsDirectoryError,
  ReadOnlySettingsFileError,
  SessionOnlySettingsError,
  SettingsConflictError,
  SettingsRemoveError,
  SettingsWriteError,
  UnconfirmedCreateError,
  UnconfirmedRemoveError,
  UnconfirmedRepairError,
  type SaveDestination,
  type SettingsChange,
  type SettingsSnapshot,
  type SettingsStore,
} from "#footer/configuration/settings-store.ts";
import type { GitState } from "#footer/integrations/git.ts";

export class ManualClock implements Clock {
  private time = Date.UTC(2026, 9, 20, 12);
  private readonly jobs = new Set<{
    at: number;
    interval?: number;
    callback: () => void;
  }>();

  now(): number {
    return this.time;
  }

  get pending(): number {
    return this.jobs.size;
  }

  set(time: number): void {
    this.time = time;
  }

  after(milliseconds: number, callback: () => void): () => void {
    return this.schedule(milliseconds, callback);
  }

  every(milliseconds: number, callback: () => void): () => void {
    return this.schedule(milliseconds, callback, milliseconds);
  }

  private schedule(
    milliseconds: number,
    callback: () => void,
    interval?: number,
  ): () => void {
    const job = { at: this.time + milliseconds, callback, interval };
    this.jobs.add(job);
    return () => {
      this.jobs.delete(job);
    };
  }

  async advance(milliseconds: number): Promise<void> {
    const end = this.time + milliseconds;
    const next = [...this.jobs]
      .filter((job) => job.at <= end)
      .toSorted((a, b) => a.at - b.at)[0];
    if (!next) {
      this.time = end;
      await setImmediate();
      return;
    }
    this.time = next.at;
    if (next.interval === undefined) {
      this.jobs.delete(next);
    } else {
      next.at += next.interval;
    }
    next.callback();
    await setImmediate();
    await this.advance(end - this.time);
  }
}

type FileDestination = Exclude<SaveDestination, { kind: "session" }>;

/**
 * An in-memory settings directory with a base file and a user file. It loads,
 * saves and resets them as `NodeSettingsStore` does: each change to a file
 * gives the directory a new revision, a save from an older snapshot fails with
 * a conflict, and the destination and the confirmations that a save needs
 * follow from the files and their write access. The directory contains no
 * symbolic links or irregular files.
 */
export class MemorySettingsStore implements SettingsStore {
  readonly path = "/agent/session-footer.json";
  readonly userPath = "/agent/session-footer.user.json";
  /** Settings files, or their directory, that the store cannot write. */
  readonly readOnly = new Set<string>();
  /** The operating-system error that every later write or removal reports. */
  failure: Error | undefined;
  private readonly files = new Map<string, string>();
  private version = 0;

  get stored(): string | undefined {
    return this.files.get(this.path);
  }

  set stored(text: string | undefined) {
    this.replace(this.path, text);
  }

  get user(): string | undefined {
    return this.files.get(this.userPath);
  }

  set user(text: string | undefined) {
    this.replace(this.userPath, text);
  }

  load(): SettingsSnapshot {
    const base = loadSettings(() => this.stored, this.path);
    const user = this.user;
    const loaded = user === undefined ? base : this.loadUser(base, user);

    return {
      loaded,
      base,
      userPath: this.userPath,
      userExists: user !== undefined,
      revision: String(this.version),
      destination: this.destination(base, loaded),
    };
  }

  save(expected: SettingsSnapshot, change: SettingsChange): SettingsSnapshot {
    const current = this.load();

    if (current.revision !== expected.revision) {
      throw new SettingsConflictError();
    }

    const destination = current.destination;

    if (destination.kind === "session") {
      throw new SessionOnlySettingsError();
    }

    if (change.kind === "reset") {
      return this.reset(current, change.confirmed === true);
    }

    if (destination.kind === "unavailable") {
      throw destination.problem;
    }

    const document = parsePresentationDocument(change.document);

    if (
      !destination.repair &&
      isDeepStrictEqual(document, presentationDocument(current.loaded.document))
    ) {
      return current;
    }

    if (destination.newUserFile && change.confirmed !== true) {
      throw new UnconfirmedCreateError(destination.path);
    }

    if (destination.repair && change.confirmed !== true) {
      throw new UnconfirmedRepairError(destination.path);
    }

    if (this.failure !== undefined) {
      throw new SettingsWriteError(destination.path, { cause: this.failure });
    }

    const persistence = current.base.document.persistence;
    const saved =
      destination.path === this.path && persistence !== undefined
        ? { ...document, persistence }
        : document;

    this.replace(destination.path, `${JSON.stringify(saved, null, 2)}\n`);

    return this.load();
  }

  private reset(
    current: SettingsSnapshot,
    confirmed: boolean,
  ): SettingsSnapshot {
    if (!current.userExists) {
      return current;
    }

    const destination = this.fileDestination(this.userPath, false, false);

    if (destination.kind === "unavailable") {
      throw destination.problem;
    }

    if (!confirmed) {
      throw new UnconfirmedRemoveError(this.userPath);
    }

    if (this.failure !== undefined) {
      throw new SettingsRemoveError(this.userPath, { cause: this.failure });
    }

    this.replace(this.userPath, undefined);

    return this.load();
  }

  private loadUser(base: LoadedSettings, text: string): LoadedSettings {
    try {
      const document = parsePresentationDocument(JSON.parse(text));

      return {
        ...resolveSettings(document),
        persistence: base.persistence,
        document,
        path: this.userPath,
        source: "file",
        diagnostic: undefined,
      };
    } catch (error) {
      const detail =
        error instanceof SettingsError
          ? error.message
          : "Check file permissions and JSON syntax";

      return {
        ...base,
        source: "fallback",
        diagnostic: `Cannot load ${this.userPath}. ${detail}; using ${this.path}.`,
      };
    }
  }

  private destination(
    base: LoadedSettings,
    loaded: LoadedSettings,
  ): SaveDestination {
    if (base.persistence === "session") {
      return { kind: "session" };
    }

    if (this.user !== undefined) {
      return this.fileDestination(
        this.userPath,
        false,
        loaded.source === "fallback",
      );
    }

    if (this.stored !== undefined && this.readOnly.has(this.path)) {
      return this.fileDestination(this.userPath, true, false);
    }

    return this.fileDestination(this.path, false, base.source === "fallback");
  }

  private fileDestination(
    path: string,
    newUserFile: boolean,
    repair: boolean,
  ): FileDestination {
    const directory = dirname(path);

    if (this.files.has(path) && this.readOnly.has(path)) {
      return {
        kind: "unavailable",
        path,
        problem: new ReadOnlySettingsFileError(path),
      };
    }

    if (this.readOnly.has(directory)) {
      return {
        kind: "unavailable",
        path,
        problem: new ReadOnlySettingsDirectoryError(directory),
      };
    }

    return { kind: "file", path, newUserFile, repair };
  }

  private replace(path: string, text: string | undefined): void {
    this.version++;

    if (text === undefined) {
      this.files.delete(path);
      return;
    }

    this.files.set(path, text);
  }
}

/**
 * A repository for the footer's Git reader. A read records the state at its
 * start, as `git status` does, and finishes after `duration` milliseconds of
 * the clock or when a held read is released.
 */
export class FakeRepository {
  state: GitState | undefined;
  failure: Error | undefined;
  duration = 0;
  private readonly clock: ManualClock;
  private gate: Promise<void> | undefined;

  constructor(clock: ManualClock) {
    this.clock = clock;
  }

  hold(): () => void {
    const gate = Promise.withResolvers<void>();
    this.gate = gate.promise;
    return () => {
      this.gate = undefined;
      gate.resolve();
    };
  }

  read = async (_cwd: string, now: number): Promise<GitState | undefined> => {
    const state =
      this.state === undefined ? undefined : { ...this.state, updatedAt: now };
    const failure = this.failure;
    const gate = this.gate;

    if (this.duration > 0) {
      const finished = Promise.withResolvers<void>();
      this.clock.after(this.duration, () => finished.resolve());
      await finished.promise;
    }

    await gate;

    if (failure) {
      throw failure;
    }

    return state;
  };
}

export function dependencies() {
  let id = 0;
  const clock = new ManualClock();
  const settingsStore = new MemorySettingsStore();
  const repository = new FakeRepository(clock);
  const errors: unknown[] = [];
  const runtime = {
    clock,
    homeDirectory: "/Users/test",
    settingsPath: "/agent/session-footer.json",
    settingsStore,
    requestId: () => `request-${++id}`,
    readGit: repository.read,
    reportError: (error: unknown) => {
      errors.push(error);
    },
  } satisfies FooterRuntime;
  return { ...runtime, repository, errors };
}
