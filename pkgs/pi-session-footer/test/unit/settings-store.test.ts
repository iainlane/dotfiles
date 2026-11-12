import {
  accessSync,
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  readdirSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { NodeSettingsStore } from "#footer/configuration/node-settings-store.ts";
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
import { thrown } from "#test/support/thrown.ts";

vi.mock("node:fs", async (original) => {
  const fs = await original<typeof import("node:fs")>();
  return {
    ...fs,
    accessSync: vi.fn<typeof accessSync>(fs.accessSync),
    renameSync: vi.fn<typeof renameSync>(fs.renameSync),
    fsyncSync: vi.fn<typeof fsyncSync>(fs.fsyncSync),
    closeSync: vi.fn<typeof closeSync>(fs.closeSync),
  };
});

const revisionPattern: unknown = expect.stringMatching(/^[0-9a-f]{64}$/);
const roots: string[] = [];
const denied = new Set<string>();
beforeEach(async () => {
  const fs = await vi.importActual<typeof import("node:fs")>("node:fs");
  denied.clear();
  vi.mocked(accessSync).mockImplementation((path, mode) => {
    if (denied.has(String(path))) {
      throw Object.assign(new Error("Permission denied"), { code: "EACCES" });
    }
    fs.accessSync(path, mode);
  });
  vi.mocked(renameSync).mockImplementation(fs.renameSync);
  vi.mocked(fsyncSync).mockImplementation(fs.fsyncSync);
  vi.mocked(closeSync).mockImplementation(fs.closeSync);
});
afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
  vi.clearAllMocks();
});
function harness() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-footer-settings-")));
  roots.push(root);
  const base = join(root, "session-footer.json");
  const user = join(root, "session-footer.user.json");
  return { root, base, user, store: new NodeSettingsStore(base) };
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
  expect(
    thrown(() =>
      h.store.save(snapshot, {
        kind: "write",
        document: { preset: "compact" },
      }),
    ),
  ).toStrictEqual(new UnconfirmedCreateError(h.user));
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
    expect(
      thrown(() =>
        h.store.save(initial, {
          kind: "write",
          document: { preset: "workflow" },
        }),
      ),
    ).toStrictEqual(new SettingsConflictError());
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
  expect(
    thrown(() =>
      h.store.save(snapshot, {
        kind: "write",
        document: { preset: "minimal" },
      }),
    ),
  ).toStrictEqual(problem);
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
  expect(
    thrown(() =>
      h.store.save(initial, {
        kind: "write",
        document: { preset: "compact" },
        confirmed: true,
      }),
    ),
  ).toStrictEqual(new SettingsConflictError());
  expect({
    link: lstatSync(h.base).isSymbolicLink(),
    target: readJson(target),
  }).toStrictEqual({ link: true, target: { preset: "minimal" } });
});

it("offers a sibling file when the regular base is not writable", () => {
  const h = harness();
  json(h.base, { preset: "rich" });
  denied.add(h.base);
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
  denied.add(h[file]);
  const snapshot = h.store.load();
  expect(
    thrown(() =>
      h.store.save(snapshot, {
        kind: "write",
        document: { preset: "minimal" },
      }),
    ),
  ).toStrictEqual(error(h[file]));
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
  expect(
    thrown(() =>
      h.store.save(initial, { kind: "write", document: { preset: "rich" } }),
    ),
  ).toStrictEqual(new UnconfirmedRepairError(h.user));
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
  expect(
    thrown(() =>
      h.store.save(snapshot, {
        kind: "write",
        document: { preset: "minimal" },
      }),
    ),
  ).toStrictEqual(new SessionOnlySettingsError());
  expect(readJson(h.user)).toStrictEqual({ preset: "compact" });
});

it("resets only on a confirmed commit and leaves the base unchanged", () => {
  const h = harness();
  json(h.base, { preset: "minimal" });
  json(h.user, { preset: "compact" });
  const snapshot = h.store.load();
  expect(thrown(() => h.store.save(snapshot, { kind: "reset" }))).toStrictEqual(
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
  const snapshot = h.store.load();
  h.store.save(snapshot, { kind: "write", document: { preset: "compact" } });
  expect({
    raw: readFileSync(h.base, "utf8"),
    renames: vi.mocked(renameSync).mock.calls,
  }).toStrictEqual({ raw, renames: [] });
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

it("checks the source again after preparing the temporary file", async () => {
  const h = harness();
  const fs = await vi.importActual<typeof import("node:fs")>("node:fs");
  json(h.base, { preset: "rich" });
  const snapshot = h.store.load();
  vi.mocked(fsyncSync).mockImplementationOnce((descriptor) => {
    fs.fsyncSync(descriptor);
    json(h.base, { preset: "minimal" });
  });
  expect(
    thrown(() =>
      h.store.save(snapshot, {
        kind: "write",
        document: { preset: "compact" },
      }),
    ),
  ).toStrictEqual(new SettingsConflictError());
  expect({
    base: readJson(h.base),
    entries: readdirSync(h.root),
    renames: vi.mocked(renameSync).mock.calls,
  }).toStrictEqual({
    base: { preset: "minimal" },
    entries: ["session-footer.json"],
    renames: [],
  });
});

it.each(["flush", "close", "rename"] as const)(
  "keeps the old file and cleans up after %s fails",
  async (operation) => {
    const h = harness();
    json(h.base, { preset: "rich" });
    const snapshot = h.store.load();
    const failure = new Error(`${operation} failed`);
    if (operation === "flush") {
      vi.mocked(fsyncSync).mockImplementationOnce(() => {
        throw failure;
      });
    }
    if (operation === "close") {
      const fs = await vi.importActual<typeof import("node:fs")>("node:fs");
      vi.mocked(closeSync).mockImplementationOnce((descriptor) => {
        fs.closeSync(descriptor);
        throw failure;
      });
    }
    if (operation === "rename") {
      vi.mocked(renameSync).mockImplementationOnce(() => {
        throw failure;
      });
    }
    expect(
      thrown(() =>
        h.store.save(snapshot, {
          kind: "write",
          document: { preset: "compact" },
        }),
      ),
    ).toStrictEqual(new SettingsWriteError(h.base, { cause: failure }));
    expect({
      base: readJson(h.base),
      entries: readdirSync(h.root),
    }).toStrictEqual({
      base: { preset: "rich" },
      entries: ["session-footer.json"],
    });
  },
);
