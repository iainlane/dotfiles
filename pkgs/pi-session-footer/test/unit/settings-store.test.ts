import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import {
  NodeSettingsStore,
  nodeSettingsFileSystem,
  type SettingsFileSystem,
} from "#footer/configuration/node-settings-store.ts";
import { loadSettings } from "#footer/configuration/settings.ts";
import {
  IrregularSettingsFileError,
  ReadOnlySettingsDirectoryError,
  ReadOnlySettingsFileError,
  SessionOnlySettingsError,
  SettingsConflictError,
  SettingsWriteError,
  SymlinkSettingsFileError,
  UnconfirmedCreateError,
  UnconfirmedRemoveError,
  UnconfirmedRepairError,
} from "#footer/configuration/settings-store.ts";

interface Failure {
  operation: "flush" | "close" | "rename";
  error: Error;
}

class FaultyFileSystem implements SettingsFileSystem {
  readonly denied = new Set<string>();
  failure: Failure | undefined;
  afterFlush: (() => void) | undefined;

  readonly fchmodSync = nodeSettingsFileSystem.fchmodSync;
  readonly lstatSync = nodeSettingsFileSystem.lstatSync;
  readonly openSync = nodeSettingsFileSystem.openSync;
  readonly readFileSync = nodeSettingsFileSystem.readFileSync;
  readonly realpathSync = nodeSettingsFileSystem.realpathSync;
  readonly rmSync = nodeSettingsFileSystem.rmSync;
  readonly statSync = nodeSettingsFileSystem.statSync;
  readonly writeFileSync = nodeSettingsFileSystem.writeFileSync;

  readonly accessSync = (path: string, mode: number): void => {
    if (this.denied.has(path)) {
      throw Object.assign(new Error("Permission denied"), { code: "EACCES" });
    }
    nodeSettingsFileSystem.accessSync(path, mode);
  };

  readonly fsyncSync = (descriptor: number): void => {
    this.fail("flush");
    nodeSettingsFileSystem.fsyncSync(descriptor);
    const afterFlush = this.afterFlush;
    this.afterFlush = undefined;
    afterFlush?.();
  };

  // Close releases the descriptor even when it reports an error, and the store
  // does not close it again.
  readonly closeSync = (descriptor: number): void => {
    nodeSettingsFileSystem.closeSync(descriptor);
    this.fail("close");
  };

  readonly renameSync = (oldPath: string, newPath: string): void => {
    this.fail("rename");
    nodeSettingsFileSystem.renameSync(oldPath, newPath);
  };

  private fail(operation: Failure["operation"]): void {
    if (this.failure?.operation !== operation) {
      return;
    }
    const { error } = this.failure;
    this.failure = undefined;
    throw error;
  }
}

const revisionPattern: unknown = expect.stringMatching(/^[0-9a-f]{64}$/);
const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});
function harness() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-footer-settings-")));
  roots.push(root);
  const base = join(root, "session-footer.json");
  const user = join(root, "session-footer.user.json");
  const files = new FaultyFileSystem();
  return { root, base, user, files, store: new NodeSettingsStore(base, files) };
}
function json(path: string, document: unknown): void {
  writeFileSync(path, JSON.stringify(document));
}
function readJson(path: string): unknown {
  const value: unknown = JSON.parse(readFileSync(path, "utf8"));
  return value;
}

it("loads defaults and creates a concise base document", () => {
  const h = harness();
  const loaded = loadSettings((): undefined => {}, h.base);
  const initial = h.store.load();
  expect(initial).toStrictEqual({
    loaded,
    base: loaded,
    userPath: h.user,
    userExists: false,
    revision: revisionPattern,
    destination: {
      kind: "file",
      path: h.base,
      newUserFile: false,
      repair: false,
    },
  });
  const document = {
    preset: "compact" as const,
    "top-left": ["directory" as const],
  };
  const saved = h.store.save(initial, { kind: "write", document });
  expect({
    document: readJson(h.base),
    userExists: existsSync(h.user),
    settings: saved.loaded,
  }).toStrictEqual({
    document,
    userExists: false,
    settings: loadSettings(() => JSON.stringify(document), h.base),
  });
});

it("updates a writable base without materialising inherited settings", () => {
  const h = harness();
  const document = {
    preset: "compact" as const,
    symbols: { planning: "[P]" },
    separators: { widgets: "" },
  };
  json(h.base, { preset: "rich", symbols: document.symbols });
  h.store.save(h.store.load(), { kind: "write", document });
  expect(readJson(h.base)).toStrictEqual(document);
});

it("creates confirmed local preferences beside a symlink without changing its target", () => {
  const h = harness();
  const target = join(h.root, "base-source.json");
  json(target, { preset: "rich" });
  symlinkSync(target, h.base);
  const snapshot = h.store.load();
  expect(snapshot.destination).toStrictEqual({
    kind: "file",
    path: h.user,
    newUserFile: true,
    repair: false,
  });
  expect(() =>
    h.store.save(snapshot, {
      kind: "write",
      document: { preset: "compact" },
    }),
  ).toThrow(new UnconfirmedCreateError(h.user));
  h.store.save(snapshot, {
    kind: "write",
    document: { preset: "compact" },
    confirmed: true,
  });
  expect({
    link: lstatSync(h.base).isSymbolicLink(),
    base: readJson(target),
    user: readJson(h.user),
  }).toStrictEqual({
    link: true,
    base: { preset: "rich" },
    user: { preset: "compact" },
  });
});

it("loads local preferences as a complete replacement without a permission flag", () => {
  const h = harness();
  json(h.base, { preset: "rich", "top-left": ["model"] });
  json(h.user, { preset: "compact" });
  expect(h.store.load()).toStrictEqual({
    loaded: loadSettings(() => '{"preset":"compact"}', h.user),
    base: loadSettings(() => '{"preset":"rich","top-left":["model"]}', h.base),
    userPath: h.user,
    userExists: true,
    revision: revisionPattern,
    destination: {
      kind: "file",
      path: h.user,
      newUserFile: false,
      repair: false,
    },
  });
});

it.each(["base", "user"] as const)(
  "does not overwrite a changed %s source",
  (file) => {
    const h = harness();
    json(h.base, { preset: "rich" });
    if (file === "user") {
      json(h.user, { preset: "compact" });
    }
    const initial = h.store.load();
    json(h[file], { preset: "minimal" });
    expect(() =>
      h.store.save(initial, {
        kind: "write",
        document: { preset: "workflow" },
      }),
    ).toThrow(new SettingsConflictError());
    expect(readJson(h[file])).toStrictEqual({ preset: "minimal" });
  },
);

it("refuses an active user symlink even if its target is writable", () => {
  const h = harness();
  const target = join(h.root, "user-source.json");
  json(h.base, { preset: "rich" });
  json(target, { preset: "compact" });
  symlinkSync(target, h.user);
  const snapshot = h.store.load();
  const problem = new SymlinkSettingsFileError(h.user);
  expect(snapshot.destination).toStrictEqual({
    kind: "unavailable",
    path: h.user,
    problem,
  });
  expect(() =>
    h.store.save(snapshot, {
      kind: "write",
      document: { preset: "minimal" },
    }),
  ).toThrow(problem);
  expect({
    link: lstatSync(h.user).isSymbolicLink(),
    target: readJson(target),
  }).toStrictEqual({ link: true, target: { preset: "compact" } });
});

it("rejects a destination that becomes a link while editing", () => {
  const h = harness();
  json(h.base, { preset: "rich" });
  const initial = h.store.load();
  const target = join(h.root, "replacement.json");
  json(target, { preset: "minimal" });
  rmSync(h.base);
  symlinkSync(target, h.base);
  expect(() =>
    h.store.save(initial, {
      kind: "write",
      document: { preset: "compact" },
      confirmed: true,
    }),
  ).toThrow(new SettingsConflictError());
  expect({
    link: lstatSync(h.base).isSymbolicLink(),
    target: readJson(target),
  }).toStrictEqual({ link: true, target: { preset: "minimal" } });
});

it("offers a sibling file when the regular base is not writable", () => {
  const h = harness();
  json(h.base, { preset: "rich" });
  h.files.denied.add(h.base);
  expect(h.store.load().destination).toStrictEqual({
    kind: "file",
    path: h.user,
    newUserFile: true,
    repair: false,
  });
});
it.each([
  {
    file: "user",
    error: (path: string) => new ReadOnlySettingsFileError(path),
  },
  {
    file: "root",
    error: (path: string) => new ReadOnlySettingsDirectoryError(path),
  },
] as const)("refuses saving when $file is not writable", ({ file, error }) => {
  const h = harness();
  json(h.base, { preset: "rich" });
  json(h.user, { preset: "compact" });
  h.files.denied.add(h[file]);
  const snapshot = h.store.load();
  expect(() =>
    h.store.save(snapshot, {
      kind: "write",
      document: { preset: "minimal" },
    }),
  ).toThrow(error(h[file]));
  expect(readJson(h.user)).toStrictEqual({ preset: "compact" });
});
it("rejects a non-regular preferences destination", () => {
  const h = harness();
  json(h.base, { preset: "rich" });
  mkdirSync(h.user);
  expect(h.store.load().destination).toStrictEqual({
    kind: "unavailable",
    path: h.user,
    problem: new IrregularSettingsFileError(h.user),
  });
});

it("uses the base on malformed user settings and requires confirmation to repair", () => {
  const h = harness();
  json(h.base, { preset: "compact" });
  writeFileSync(h.user, '{"private-value": "sensitive');
  const initial = h.store.load();
  expect({
    preset: initial.loaded.preset,
    document: initial.loaded.document,
    diagnostic: initial.loaded.diagnostic?.includes(h.user),
    leaked: initial.loaded.diagnostic?.includes("sensitive"),
  }).toStrictEqual({
    preset: "compact",
    document: { preset: "compact" },
    diagnostic: true,
    leaked: false,
  });
  expect(() =>
    h.store.save(initial, { kind: "write", document: { preset: "rich" } }),
  ).toThrow(new UnconfirmedRepairError(h.user));
  h.store.save(initial, {
    kind: "write",
    document: { preset: "rich" },
    confirmed: true,
  });
  expect(readJson(h.user)).toStrictEqual({ preset: "rich" });
});

it("preserves session-only lifetime independently of local appearance", () => {
  const h = harness();
  json(h.base, { preset: "rich", persistence: "session" });
  json(h.user, { preset: "compact" });
  const snapshot = h.store.load();
  expect({
    preset: snapshot.loaded.preset,
    persistence: snapshot.loaded.persistence,
    destination: snapshot.destination,
  }).toStrictEqual({
    preset: "compact",
    persistence: "session",
    destination: { kind: "session" },
  });
  expect(() =>
    h.store.save(snapshot, {
      kind: "write",
      document: { preset: "minimal" },
    }),
  ).toThrow(new SessionOnlySettingsError());
  expect(readJson(h.user)).toStrictEqual({ preset: "compact" });
});

it("resets only on a confirmed commit and leaves the base unchanged", () => {
  const h = harness();
  json(h.base, { preset: "minimal" });
  json(h.user, { preset: "compact" });
  const snapshot = h.store.load();
  expect(() => h.store.save(snapshot, { kind: "reset" })).toThrow(
    new UnconfirmedRemoveError(h.user),
  );
  expect(readJson(h.user)).toStrictEqual({ preset: "compact" });
  const saved = h.store.save(snapshot, { kind: "reset", confirmed: true });
  expect({
    userExists: existsSync(h.user),
    loaded: saved.loaded,
  }).toStrictEqual({
    userExists: false,
    loaded: loadSettings(() => '{"preset":"minimal"}', h.base),
  });
});

it("keeps an unchanged document untouched", () => {
  const h = harness();
  const raw = '{ "preset": "compact" }\n';
  writeFileSync(h.base, raw);
  const inode = lstatSync(h.base).ino;
  const snapshot = h.store.load();
  h.store.save(snapshot, { kind: "write", document: { preset: "compact" } });
  expect({
    raw: readFileSync(h.base, "utf8"),
    inode: lstatSync(h.base).ino,
    entries: readdirSync(h.root),
  }).toStrictEqual({ raw, inode, entries: ["session-footer.json"] });
});

it("preserves existing permissions during atomic replacement", () => {
  const h = harness();
  json(h.base, { preset: "rich" });
  chmodSync(h.base, 0o640);
  h.store.save(h.store.load(), {
    kind: "write",
    document: { preset: "compact" },
  });
  expect({
    mode: lstatSync(h.base).mode & 0o777,
    document: readJson(h.base),
  }).toStrictEqual({ mode: 0o640, document: { preset: "compact" } });
});

it("checks the source again after preparing the temporary file", () => {
  const h = harness();
  json(h.base, { preset: "rich" });
  const snapshot = h.store.load();
  h.files.afterFlush = () => json(h.base, { preset: "minimal" });
  expect(() =>
    h.store.save(snapshot, {
      kind: "write",
      document: { preset: "compact" },
    }),
  ).toThrow(new SettingsConflictError());
  expect({
    base: readJson(h.base),
    entries: readdirSync(h.root),
  }).toStrictEqual({
    base: { preset: "minimal" },
    entries: ["session-footer.json"],
  });
});

it.each(["flush", "close", "rename"] as const)(
  "keeps the old file and cleans up after %s fails",
  (operation) => {
    const h = harness();
    json(h.base, { preset: "rich" });
    const snapshot = h.store.load();
    const error = new Error(`${operation} failed`);
    h.files.failure = { operation, error };
    expect(() =>
      h.store.save(snapshot, {
        kind: "write",
        document: { preset: "compact" },
      }),
    ).toThrow(new SettingsWriteError(h.base, { cause: error }));
    expect({
      base: readJson(h.base),
      entries: readdirSync(h.root),
    }).toStrictEqual({
      base: { preset: "rich" },
      entries: ["session-footer.json"],
    });
  },
);
