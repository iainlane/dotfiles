import { expect, it, vi } from "vitest";
import {
  AppearanceTransaction,
  type AppearanceEffects,
} from "#footer/configuration/appearance-transaction.ts";
import { CustomiserView } from "#footer/ui/customiser/customiser-view.ts";
import { createCustomiserRoot } from "#footer/ui/customiser/customiser-pages.ts";
import type { CustomiserEnvironment } from "#footer/ui/customiser/customiser-page.ts";
import {
  loadSettings,
  type PresentationDocument,
} from "#footer/configuration/settings.ts";
import {
  SettingsStoreError,
  type SettingsSnapshot,
  type SettingsStore,
} from "#footer/configuration/settings-store.ts";
import { editorFixture } from "#test/support/editor.ts";
import { KeybindingsManager } from "#test/support/keybindings.ts";

const rich: PresentationDocument = { preset: "rich" };

function fixture(initial = rich) {
  const native = editorFixture();
  native.tui.terminal = { ...native.tui.terminal, rows: 40 };
  const loaded = loadSettings(
    () => '{"preset":"rich"}',
    "/agent/session-footer.json",
  );
  const source: SettingsSnapshot = {
    loaded,
    base: loaded,
    userPath: "/agent/session-footer.user.json",
    userExists: false,
    revision: "r1",
    destination: {
      kind: "file",
      path: loaded.path,
      newUserFile: false,
      repair: false,
    },
  };
  const save = vi.fn<SettingsStore["save"]>(() => source);
  const effects = {
    store: { load: () => source, save },
    preview: vi.fn<AppearanceEffects["preview"]>(),
    saved: vi.fn<AppearanceEffects["saved"]>(),
    reloaded: vi.fn<AppearanceEffects["reloaded"]>(),
    applied: vi.fn<AppearanceEffects["applied"]>(),
    finished: vi.fn<AppearanceEffects["finished"]>(),
  };
  const transaction = new AppearanceTransaction(source, initial, effects);
  const env: CustomiserEnvironment = {
    tui: native.tui,
    keys: native.keys,
    theme: () => ({
      fg: (_colour, value) => value,
      bold: (value) => value,
      style: (value) => value,
    }),
    composerHeight: () => 3,
    presentationMode: () => "composer",
    sessionApplied: () => false,
    transaction,
    store: effects.store,
    sourceIds: () => [],
    reload: vi.fn<() => void>(),
    homeDirectory: "/Users/test",
  };
  const view = new CustomiserView(env, (navigation) =>
    createCustomiserRoot(env, navigation),
  );
  view.focused = true;
  const screen = () => view.render(100).join("\n");
  const select = (label: string) => {
    for (let attempts = 0; attempts < 100; attempts++) {
      const lines = view.render(100);
      if (lines.some((line) => line.startsWith("→ ") && line.includes(label))) {
        return;
      }
      view.handleInput("\u001B[B");
    }
    throw new Error(`Missing selectable action: ${label}\n${screen()}`);
  };
  const choose = (label: string) => {
    select(label);
    view.handleInput("\r");
    screen();
  };
  return {
    env,
    source,
    effects,
    save,
    transaction,
    view,
    screen,
    select,
    choose,
  };
}
it.each([
  { initial: { preset: "rich" }, unsaved: false },
  { initial: { preset: "compact" }, unsaved: true },
] as const)(
  "marks a draft that differs from the saved settings: $initial.preset",
  ({ initial, unsaved }) => {
    expect(fixture(initial).screen().includes("not saved")).toBe(unsaved);
  },
);
it("uses configured bindings for controls and hints", () => {
  const h = fixture();
  h.env.keys = new KeybindingsManager({
    "tui.select.down": "j",
    "tui.select.confirm": "o",
    "tui.select.cancel": "q",
  });
  expect(h.screen()).toContain("o edit · q cancel");
  h.view.handleInput("o");
  h.screen();
  h.view.handleInput("j");
  h.view.handleInput("o");
  expect(h.transaction.document).toStrictEqual({ preset: "compact" });
  h.view.handleInput("q");
  expect({
    writes: h.save.mock.calls,
    closed: h.transaction.closed,
  }).toStrictEqual({ writes: [], closed: true });
});
it("adds plain widgets, preserves explicit empty rows and resets only the edited row", () => {
  const h = fixture();
  h.transaction.replace({ preset: "rich", "top-right": [], "bottom-left": [] });
  h.choose("Widgets");
  h.choose("Top right");
  h.choose("Add widget");
  h.view.handleInput("cache");
  h.choose("Cache");
  expect(h.transaction.document).toStrictEqual({
    preset: "rich",
    "top-right": ["cache"],
    "bottom-left": [],
  });
  h.choose("Cache");
  h.choose("Remove");
  expect(h.transaction.document).toStrictEqual({
    preset: "rich",
    "top-right": [],
    "bottom-left": [],
  });
  h.choose("Reset row");
  expect({
    document: h.transaction.document,
    writes: h.save.mock.calls,
  }).toStrictEqual({
    document: { preset: "rich", "bottom-left": [] },
    writes: [],
  });
});
it("writes an explicit alias object from the symbol picker", () => {
  const h = fixture();
  h.choose("Extension symbols");
  h.choose("planning");
  h.choose("Symbol");
  h.view.handleInput("git");
  h.choose(" git");
  expect({
    document: h.transaction.document,
    writes: h.save.mock.calls,
  }).toStrictEqual({
    document: { preset: "rich", symbols: { planning: { alias: "git" } } },
    writes: [],
  });
});
it("previews profiles on highlight and saves only at the root", () => {
  const h = fixture();
  h.choose("Profile");
  h.select("Compact");
  expect({
    draft: h.transaction.document,
    preview: h.transaction.presentation,
    saves: h.save.mock.calls,
  }).toStrictEqual({
    draft: { preset: "rich" },
    preview: { preset: "compact" },
    saves: [],
  });
  h.view.handleInput("\u001B");
  expect(h.transaction.presentation).toStrictEqual({ preset: "rich" });
  h.choose("Profile");
  h.choose("Compact");
  expect({
    draft: h.transaction.document,
    saves: h.save.mock.calls,
  }).toStrictEqual({ draft: { preset: "compact" }, saves: [] });
  h.choose("Save & use");
  expect(h.save.mock.calls).toStrictEqual([
    [
      h.source,
      { kind: "write", document: { preset: "compact" }, confirmed: false },
    ],
  ]);
});
it("accepts navigation immediately after returning from a picker", () => {
  const h = fixture();
  h.choose("Profile");
  h.select("Compact");
  h.view.handleInput("\r");
  for (let count = 0; count < 5; count++) {
    h.view.handleInput("\u001B[B");
  }
  expect(h.screen()).toContain("enter save");
});
it("keeps independent colours in one draft and cancels the whole flow at the root", () => {
  const h = fixture();
  h.choose("Widgets");
  h.choose("Top left");
  h.choose("Git");
  h.choose("Customise");
  h.choose("Symbol colour");
  h.choose("Accent");
  h.choose("Text colour");
  h.choose("Text");
  expect(h.transaction.document["top-left"]).toStrictEqual([
    "model",
    "thinking",
    "tier",
    "directory",
    { id: "git", colour: "text", symbol: { colour: "accent" } },
    "git-operation",
    "git-conflicts",
    "pr",
  ]);
  for (let index = 0; index < 4; index++) {
    h.view.handleInput("\u001B");
  }
  expect(h.screen()).toContain("Save & use");
  h.view.handleInput("\u001B");
  expect({
    saves: h.save.mock.calls,
    preview: h.effects.preview.mock.calls.at(-1),
    finished: h.effects.finished.mock.calls,
  }).toStrictEqual({ saves: [], preview: [undefined], finished: [[]] });
});
it("keeps invalid custom text local and restores the accepted field on Escape", () => {
  const h = fixture();
  h.choose("Separators");
  h.choose("Between widgets");
  h.choose("Custom");
  for (const character of "123456789") {
    h.view.handleInput(character);
  }
  expect(h.screen()).toContain("8 columns");
  expect(h.transaction.document).toStrictEqual({ preset: "rich" });
  h.view.handleInput("\u001B");
  expect(h.transaction.presentation).toStrictEqual({ preset: "rich" });
  expect(h.save.mock.calls).toStrictEqual([]);
});
it("retains the draft on save failure until session application is explicitly selected", () => {
  const h = fixture();
  h.save.mockImplementation(() => {
    throw new SettingsStoreError("io", "Permission denied");
  });
  h.choose("Profile");
  h.choose("Compact");
  h.choose("Save & use");
  expect({
    error: h.screen().includes("Couldn't save"),
    applied: h.effects.applied.mock.calls,
    closed: h.transaction.closed,
    preview: h.transaction.presentation,
  }).toStrictEqual({
    error: true,
    applied: [],
    closed: false,
    preview: { preset: "compact" },
  });
  h.choose("Use for this session");
  expect(h.effects.applied.mock.calls).toStrictEqual([[{ preset: "compact" }]]);
});
it("keeps an unavailable persistent destination distinct from session-only settings", () => {
  const h = fixture();
  h.source.destination = {
    kind: "unavailable",
    path: h.source.loaded.path,
    reason: "Directory is not writable",
  };
  h.save.mockImplementation(() => {
    throw new SettingsStoreError("unavailable", "Directory is not writable");
  });
  h.choose("Profile");
  h.choose("Compact");
  h.choose("Save & use");
  expect({
    failed: h.screen().includes("Couldn\u0027t save"),
    applied: h.effects.applied.mock.calls,
    closed: h.transaction.closed,
  }).toStrictEqual({ failed: true, applied: [], closed: false });
});
it("allows arbitrary source IDs without shadowing the add-source action", () => {
  const h = fixture();
  h.transaction.replace({ symbols: { "add-source": "!" } });
  h.choose("Extension symbols");
  h.choose("Add source");
  expect(h.screen()).toContain("Extension source ID");
});
it("confirms the first local-preferences save without saving when the confirmation opens", () => {
  const h = fixture();
  h.source.destination = {
    kind: "file",
    path: h.source.userPath,
    newUserFile: true,
    repair: false,
  };
  h.choose("Profile");
  h.choose("Compact");
  h.choose("Save & use");
  expect({
    title: h.screen().includes("Save user settings"),
    saves: h.save.mock.calls,
  }).toStrictEqual({ title: true, saves: [] });
  h.choose("Save & use");
  expect(h.save.mock.calls).toStrictEqual([
    [
      h.source,
      { kind: "write", document: { preset: "compact" }, confirmed: true },
    ],
  ]);
});
