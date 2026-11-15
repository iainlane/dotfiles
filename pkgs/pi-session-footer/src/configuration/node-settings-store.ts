import {
  accessSync,
  closeSync,
  constants,
  fchmodSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
  type Stats,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { basename, dirname, join, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import {
  loadSettings,
  parsePresentationDocument,
  presentationDocument,
  resolveSettings,
  type PresentationDocument,
} from "./settings.ts";
import { SettingsError } from "./settings-errors.ts";
import {
  IrregularSettingsFileError,
  ReadOnlySettingsDirectoryError,
  ReadOnlySettingsFileError,
  SessionOnlySettingsError,
  SettingsConflictError,
  SettingsDestinationChangedError,
  SettingsReadError,
  SettingsRemoveError,
  SettingsStoreError,
  SettingsWriteError,
  SymlinkSettingsFileError,
  UnconfirmedCreateError,
  UnconfirmedRemoveError,
  UnconfirmedRepairError,
  type SaveDestination,
  type SettingsChange,
  type SettingsSnapshot,
  type SettingsStore,
} from "./settings-store.ts";

export interface SettingsFileSystem {
  accessSync: (path: string, mode: number) => void;
  closeSync: (descriptor: number) => void;
  fchmodSync: (descriptor: number, mode: number) => void;
  fsyncSync: (descriptor: number) => void;
  lstatSync: (path: string) => Stats;
  openSync: (path: string, flags: number, mode: number) => number;
  readFileSync: (path: string, encoding: "utf8") => string;
  realpathSync: (path: string) => string;
  renameSync: (oldPath: string, newPath: string) => void;
  rmSync: (path: string, options?: { force: boolean }) => void;
  statSync: (path: string) => Stats;
  writeFileSync: (descriptor: number, data: string, encoding: "utf8") => void;
}

export const nodeSettingsFileSystem: SettingsFileSystem = {
  accessSync,
  closeSync,
  fchmodSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
};

interface SettingsFile {
  path: string;
  kind: "missing" | "file" | "symlink" | "other";
  stat: Stats | undefined;
  content: string | undefined;
  error: Error | undefined;
}
type FileFingerprint = readonly [
  path: string,
  kind: SettingsFile["kind"],
  identity: readonly number[] | undefined,
  content: string | undefined,
  error: string | undefined,
];
function readError(path: string, error: unknown): Error {
  return error instanceof Error
    ? error
    : new SettingsReadError(path, { cause: error });
}
interface Inspection {
  snapshot: SettingsSnapshot;
  base: SettingsFile;
  user: SettingsFile;
}
function errorCode(error: unknown): string | undefined {
  return error instanceof Error &&
    "code" in error &&
    typeof error.code === "string"
    ? error.code
    : undefined;
}
function content(file: SettingsFile): string | undefined {
  if (file.error !== undefined) {
    throw file.error;
  }
  return file.content;
}
function fingerprint(file: SettingsFile): FileFingerprint {
  const stat = file.stat;
  return [
    file.path,
    file.kind,
    stat === undefined
      ? undefined
      : [stat.dev, stat.ino, stat.mode, stat.size, stat.mtimeMs, stat.ctimeMs],
    file.content,
    errorCode(file.error),
  ];
}
type FileDestination = Exclude<SaveDestination, { kind: "session" }>;

export class NodeSettingsStore implements SettingsStore {
  private readonly basePath: string | (() => string);
  private readonly files: SettingsFileSystem;

  constructor(basePath: string | (() => string), files: SettingsFileSystem) {
    this.basePath = basePath;
    this.files = files;
  }

  load(): SettingsSnapshot {
    return this.inspect().snapshot;
  }

  private selectedPath(): string {
    const selected =
      typeof this.basePath === "string" ? this.basePath : this.basePath();
    const path = resolve(selected);
    try {
      return join(this.files.realpathSync(dirname(path)), basename(path));
    } catch {
      return path;
    }
  }

  private inspectFile(path: string): SettingsFile {
    let stat: Stats;
    try {
      stat = this.files.lstatSync(path);
    } catch (error) {
      return {
        path,
        kind: errorCode(error) === "ENOENT" ? "missing" : "other",
        stat: undefined,
        content: undefined,
        error:
          errorCode(error) === "ENOENT" ? undefined : readError(path, error),
      };
    }
    const kind = stat.isSymbolicLink()
      ? "symlink"
      : stat.isFile()
        ? "file"
        : "other";
    try {
      if (
        kind === "other" ||
        (kind === "symlink" && !this.files.statSync(path).isFile())
      ) {
        throw new IrregularSettingsFileError(path);
      }
      return {
        path,
        kind,
        stat,
        content: this.files.readFileSync(path, "utf8"),
        error: undefined,
      };
    } catch (error) {
      return {
        path,
        kind,
        stat,
        content: undefined,
        error: readError(path, error),
      };
    }
  }

  private accessible(path: string, mode: number): boolean {
    try {
      this.files.accessSync(path, mode);
      return true;
    } catch {
      return false;
    }
  }

  private parentIdentity(path: string): string {
    try {
      const stat = this.files.statSync(dirname(path));
      return `${stat.dev}:${stat.ino}`;
    } catch {
      return "missing";
    }
  }

  private fileDestination(
    file: SettingsFile,
    newUserFile: boolean,
    repair: boolean,
  ): FileDestination {
    const fail = (problem: SettingsStoreError): FileDestination => ({
      kind: "unavailable",
      path: file.path,
      problem,
    });
    if (file.kind === "symlink") {
      return fail(new SymlinkSettingsFileError(file.path));
    }
    if (file.kind === "other") {
      return fail(new IrregularSettingsFileError(file.path));
    }
    if (file.kind === "file" && !this.accessible(file.path, constants.W_OK)) {
      return fail(new ReadOnlySettingsFileError(file.path));
    }
    const directory = dirname(file.path);
    if (!this.accessible(directory, constants.W_OK | constants.X_OK)) {
      return fail(new ReadOnlySettingsDirectoryError(directory));
    }
    return { kind: "file", path: file.path, newUserFile, repair };
  }

  private inspect(): Inspection {
    const path = this.selectedPath();
    const base = this.inspectFile(path);
    const user = this.inspectFile(
      join(dirname(path), "session-footer.user.json"),
    );
    const baseSettings = loadSettings(() => content(base), path);
    let loaded = baseSettings;
    let invalidUser = false;
    if (user.kind !== "missing") {
      try {
        const document = parsePresentationDocument(
          JSON.parse(content(user) ?? ""),
        );
        loaded = {
          ...resolveSettings(document),
          persistence: baseSettings.persistence,
          document,
          path: user.path,
          source: "file",
          diagnostic: undefined,
        };
      } catch (error) {
        invalidUser = true;
        const detail =
          error instanceof SettingsError
            ? error.message
            : "Check file permissions and JSON syntax";
        loaded = {
          ...baseSettings,
          source: "fallback",
          diagnostic: `Cannot load ${user.path}. ${detail}; using ${base.path}.`,
        };
      }
    }
    let destination: SaveDestination;
    if (baseSettings.persistence === "session") {
      destination = { kind: "session" };
    } else if (user.kind !== "missing") {
      destination = this.fileDestination(user, false, invalidUser);
    } else if (
      base.kind === "symlink" ||
      (base.kind === "file" && !this.accessible(base.path, constants.W_OK))
    ) {
      destination = this.fileDestination(user, true, false);
    } else {
      destination = this.fileDestination(
        base,
        false,
        baseSettings.source === "fallback",
      );
    }
    const revision = createHash("sha256")
      .update(
        JSON.stringify([
          this.parentIdentity(path),
          fingerprint(base),
          fingerprint(user),
        ]),
      )
      .digest("hex");
    return {
      base,
      user,
      snapshot: {
        loaded,
        base: baseSettings,
        userPath: user.path,
        userExists: user.kind !== "missing",
        revision,
        destination,
      },
    };
  }

  private current(expected: SettingsSnapshot): Inspection {
    const current = this.inspect();
    if (current.snapshot.revision !== expected.revision) {
      throw new SettingsConflictError();
    }
    if (current.snapshot.destination.kind === "session") {
      throw new SessionOnlySettingsError();
    }
    return current;
  }

  save(expected: SettingsSnapshot, change: SettingsChange): SettingsSnapshot {
    const current = this.current(expected);
    if (change.kind === "reset") {
      return this.reset(current, change.confirmed === true);
    }
    const destination = current.snapshot.destination;
    if (destination.kind === "session") {
      throw new SessionOnlySettingsError();
    }
    if (destination.kind === "unavailable") {
      throw destination.problem;
    }
    const document = parsePresentationDocument(change.document);
    if (
      !destination.repair &&
      isDeepStrictEqual(
        document,
        presentationDocument(current.snapshot.loaded.document),
      )
    ) {
      return current.snapshot;
    }
    if (destination.newUserFile && change.confirmed !== true) {
      throw new UnconfirmedCreateError(destination.path);
    }
    if (destination.repair && change.confirmed !== true) {
      throw new UnconfirmedRepairError(destination.path);
    }
    const saved =
      destination.path === current.base.path &&
      current.snapshot.base.document.persistence !== undefined
        ? {
            ...document,
            persistence: current.snapshot.base.document.persistence,
          }
        : document;
    const target =
      destination.path === current.base.path ? current.base : current.user;
    this.write(current.snapshot, target, saved);
    return this.load();
  }

  private write(
    expected: SettingsSnapshot,
    target: SettingsFile,
    document: PresentationDocument,
  ): void {
    const temporary = join(
      dirname(target.path),
      `.session-footer-${randomUUID()}.tmp`,
    );
    let descriptor: number | undefined;
    try {
      descriptor = this.files.openSync(
        temporary,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL,
        0o600,
      );
      if (target.stat !== undefined) {
        this.files.fchmodSync(descriptor, target.stat.mode & 0o777);
      }
      this.files.writeFileSync(
        descriptor,
        `${JSON.stringify(document, null, 2)}\n`,
        "utf8",
      );
      this.files.fsyncSync(descriptor);
      const descriptorToClose = descriptor;
      // A failed close may already have released the descriptor.
      descriptor = undefined;
      this.files.closeSync(descriptorToClose);
      const checked = this.current(expected).snapshot.destination;
      if (checked.kind === "unavailable") {
        throw checked.problem;
      }
      if (checked.kind !== "file" || checked.path !== target.path) {
        throw new SettingsDestinationChangedError(target.path);
      }
      this.files.renameSync(temporary, target.path);
    } catch (error) {
      if (error instanceof SettingsStoreError) {
        throw error;
      }
      throw new SettingsWriteError(target.path, { cause: error });
    } finally {
      if (descriptor !== undefined) {
        this.files.closeSync(descriptor);
      }
      this.files.rmSync(temporary, { force: true });
    }
  }

  private reset(current: Inspection, confirmed: boolean): SettingsSnapshot {
    if (current.user.kind === "missing") {
      return current.snapshot;
    }
    const destination = this.fileDestination(current.user, false, false);
    if (destination.kind === "unavailable") {
      throw destination.problem;
    }
    if (!confirmed) {
      throw new UnconfirmedRemoveError(current.user.path);
    }
    this.current(current.snapshot);
    try {
      this.files.rmSync(current.user.path);
    } catch (error) {
      throw new SettingsRemoveError(current.user.path, { cause: error });
    }
    return this.load();
  }
}
