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
import { SettingsError } from "./appearance.ts";
import {
  SettingsStoreError,
  type SaveDestination,
  type SettingsChange,
  type SettingsSnapshot,
  type SettingsStore,
} from "./settings-store.ts";

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
function readError(error: unknown): Error {
  return error instanceof Error
    ? error
    : new Error("Could not read settings", { cause: error });
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
function inspectFile(path: string): SettingsFile {
  let stat: Stats;
  try {
    stat = lstatSync(path);
  } catch (error) {
    return {
      path,
      kind: errorCode(error) === "ENOENT" ? "missing" : "other",
      stat: undefined,
      content: undefined,
      error: errorCode(error) === "ENOENT" ? undefined : readError(error),
    };
  }
  const kind = stat.isSymbolicLink()
    ? "symlink"
    : stat.isFile()
      ? "file"
      : "other";
  try {
    if (kind === "other" || (kind === "symlink" && !statSync(path).isFile())) {
      throw new SettingsStoreError(
        "unavailable",
        "Expected a regular settings file",
      );
    }
    return {
      path,
      kind,
      stat,
      content: readFileSync(path, "utf8"),
      error: undefined,
    };
  } catch (error) {
    return { path, kind, stat, content: undefined, error: readError(error) };
  }
}
function content(file: SettingsFile): string | undefined {
  if (file.error !== undefined) {
    throw file.error;
  }
  return file.content;
}
function accessible(path: string, mode: number): boolean {
  try {
    accessSync(path, mode);
    return true;
  } catch {
    return false;
  }
}
function parentIdentity(path: string): string {
  try {
    const stat = statSync(dirname(path));
    return `${stat.dev}:${stat.ino}`;
  } catch {
    return "missing";
  }
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
function fileDestination(
  file: SettingsFile,
  newUserFile: boolean,
  repair: boolean,
): SaveDestination {
  const fail = (reason: string): SaveDestination => ({
    kind: "unavailable",
    path: file.path,
    reason,
  });
  if (file.kind === "symlink") {
    return fail("Cannot save to a symbolic link");
  }
  if (file.kind === "other") {
    return fail("Expected a regular settings file");
  }
  if (file.kind === "file" && !accessible(file.path, constants.W_OK)) {
    return fail("The settings file is not writable");
  }
  if (!accessible(dirname(file.path), constants.W_OK | constants.X_OK)) {
    return fail("The settings directory is not writable");
  }
  return { kind: "file", path: file.path, newUserFile, repair };
}

export class NodeSettingsStore implements SettingsStore {
  constructor(private readonly basePath: string | (() => string)) {}

  load(): SettingsSnapshot {
    return this.inspect().snapshot;
  }

  private selectedPath(): string {
    const selected =
      typeof this.basePath === "string" ? this.basePath : this.basePath();
    const path = resolve(selected);
    try {
      return join(realpathSync(dirname(path)), basename(path));
    } catch {
      return path;
    }
  }

  private inspect(): Inspection {
    const path = this.selectedPath();
    const base = inspectFile(path);
    const user = inspectFile(join(dirname(path), "session-footer.user.json"));
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
      destination = fileDestination(user, false, invalidUser);
    } else if (
      base.kind === "symlink" ||
      (base.kind === "file" && !accessible(base.path, constants.W_OK))
    ) {
      destination = fileDestination(user, true, false);
    } else {
      destination = fileDestination(
        base,
        false,
        baseSettings.source === "fallback",
      );
    }
    const revision = createHash("sha256")
      .update(
        JSON.stringify([
          parentIdentity(path),
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
      throw new SettingsStoreError(
        "conflict",
        "Settings changed on disk. Reopen the editor before saving",
      );
    }
    if (current.snapshot.destination.kind === "session") {
      throw new SettingsStoreError(
        "session",
        "This profile uses session-only changes",
      );
    }
    return current;
  }

  save(expected: SettingsSnapshot, change: SettingsChange): SettingsSnapshot {
    const current = this.current(expected);
    if (change.kind === "reset") {
      return this.reset(current, change.confirmed === true);
    }
    const destination = current.snapshot.destination;
    if (destination.kind !== "file") {
      throw new SettingsStoreError(
        "unavailable",
        destination.kind === "unavailable"
          ? destination.reason
          : "This profile uses session-only changes",
      );
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
      throw new SettingsStoreError(
        "confirmation",
        "Confirm creating user settings",
      );
    }
    if (destination.repair && change.confirmed !== true) {
      throw new SettingsStoreError(
        "confirmation",
        "Confirm replacing invalid settings",
      );
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
      descriptor = openSync(
        temporary,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL,
        0o600,
      );
      if (target.stat !== undefined) {
        fchmodSync(descriptor, target.stat.mode & 0o777);
      }
      writeFileSync(
        descriptor,
        `${JSON.stringify(document, null, 2)}\n`,
        "utf8",
      );
      fsyncSync(descriptor);
      const descriptorToClose = descriptor;
      // A failed close may already have released the descriptor.
      descriptor = undefined;
      closeSync(descriptorToClose);
      const checked = this.current(expected).snapshot.destination;
      if (checked.kind !== "file" || checked.path !== target.path) {
        throw new SettingsStoreError(
          "unavailable",
          checked.kind === "unavailable"
            ? checked.reason
            : "The settings destination changed",
        );
      }
      renameSync(temporary, target.path);
    } catch (error) {
      if (error instanceof SettingsStoreError) {
        throw error;
      }
      throw new SettingsStoreError(
        "io",
        `Could not save ${target.path}: ${errorCode(error) ?? "I/O error"}`,
        { cause: error },
      );
    } finally {
      if (descriptor !== undefined) {
        closeSync(descriptor);
      }
      rmSync(temporary, { force: true });
    }
  }

  private reset(current: Inspection, confirmed: boolean): SettingsSnapshot {
    if (current.user.kind === "missing") {
      return current.snapshot;
    }
    const destination = fileDestination(current.user, false, false);
    if (destination.kind !== "file") {
      throw new SettingsStoreError(
        "unavailable",
        destination.kind === "unavailable"
          ? destination.reason
          : "Cannot remove user settings",
      );
    }
    if (!confirmed) {
      throw new SettingsStoreError(
        "confirmation",
        "Confirm removing user settings",
      );
    }
    this.current(current.snapshot);
    try {
      rmSync(current.user.path);
    } catch (error) {
      throw new SettingsStoreError(
        "io",
        `Could not remove ${current.user.path}: ${errorCode(error) ?? "I/O error"}`,
        { cause: error },
      );
    }
    return this.load();
  }
}
