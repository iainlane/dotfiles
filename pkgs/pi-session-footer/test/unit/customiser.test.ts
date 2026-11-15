import { expect, it } from "vitest";
import { AppearanceTransaction } from "#footer/configuration/appearance-transaction.ts";
import { CustomiserView } from "#footer/ui/customiser/customiser-view.ts";
import { createCustomiserRoot } from "#footer/ui/customiser/customiser-pages.ts";
import type { CustomiserEnvironment } from "#footer/ui/customiser/customiser-page.ts";
import { storeEffects } from "#test/support/appearance.ts";
import { MemorySettingsStore } from "#test/support/dependencies.ts";
import { editorFixture } from "#test/support/editor.ts";
import { KeybindingsManager } from "#test/support/keybindings.ts";

function fixture(prepare: (store: MemorySettingsStore) => void = () => {}) {
  const native = editorFixture();
  native.tui.terminal = { ...native.tui.terminal, rows: 40 };
  const store = new MemorySettingsStore();
  store.stored = '{"preset":"rich"}';
  prepare(store);
  const source = store.load();
  const transaction = new AppearanceTransaction(
    source,
    { preset: "rich" },
    storeEffects(store),
  );
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
    store,
    sourceIds: () => [],
    reload: () => transaction.reload(store.load()),
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
    store,
    transaction,
    view,
    screen,
    select,
    choose,
  };
}
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
    stored: h.store.load(),
    closed: h.transaction.closed,
  }).toStrictEqual({ stored: h.source, closed: true });
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
    stored: h.store.load(),
  }).toStrictEqual({
    document: { preset: "rich", "bottom-left": [] },
    stored: h.source,
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
    stored: h.store.load(),
  }).toStrictEqual({
    document: { preset: "rich", symbols: { planning: { alias: "git" } } },
    stored: h.source,
  });
});
it("previews profiles on highlight and saves only at the root", () => {
  const h = fixture();
  h.choose("Profile");
  h.select("Compact");
  expect({
    draft: h.transaction.document,
    preview: h.transaction.presentation,
    stored: h.store.load(),
  }).toStrictEqual({
    draft: { preset: "rich" },
    preview: { preset: "compact" },
    stored: h.source,
  });
  h.view.handleInput("\u001B");
  expect(h.transaction.presentation).toStrictEqual({ preset: "rich" });
  h.choose("Profile");
  h.choose("Compact");
  expect({
    draft: h.transaction.document,
    stored: h.store.load(),
  }).toStrictEqual({ draft: { preset: "compact" }, stored: h.source });
  h.choose("Save & use");
  expect(h.store.load().loaded.document).toStrictEqual({ preset: "compact" });
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
    stored: h.store.load(),
    closed: h.transaction.closed,
  }).toStrictEqual({ stored: h.source, closed: true });
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
  expect(h.store.load()).toStrictEqual(h.source);
});
it("retains the draft on save failure until session application is explicitly selected", () => {
  const h = fixture((store) => {
    store.failure = Object.assign(new Error("Permission denied"), {
      code: "EACCES",
    });
  });
  h.choose("Profile");
  h.choose("Compact");
  h.choose("Save & use");
  expect({
    error: h.screen().includes("Couldn't save"),
    closed: h.transaction.closed,
    preview: h.transaction.presentation,
  }).toStrictEqual({
    error: true,
    closed: false,
    preview: { preset: "compact" },
  });
  h.choose("Use for this session");
  expect({
    stored: h.store.load(),
    closed: h.transaction.closed,
  }).toStrictEqual({ stored: h.source, closed: true });
});
it("keeps an unavailable persistent destination distinct from session-only settings", () => {
  const h = fixture((store) => {
    store.readOnly.add("/agent");
  });
  h.choose("Profile");
  h.choose("Compact");
  h.choose("Save & use");
  expect({
    failed: h.screen().includes("Couldn\u0027t save"),
    closed: h.transaction.closed,
    stored: h.store.load(),
  }).toStrictEqual({ failed: true, closed: false, stored: h.source });
});
it("allows arbitrary source IDs without shadowing the add-source action", () => {
  const h = fixture();
  h.transaction.replace({ symbols: { "add-source": "!" } });
  h.choose("Extension symbols");
  h.choose("Add source");
  expect(h.screen()).toContain("Extension source ID");
});
it("confirms the first local-preferences save without saving when the confirmation opens", () => {
  const h = fixture((store) => {
    store.readOnly.add(store.path);
  });
  h.choose("Profile");
  h.choose("Compact");
  h.choose("Save & use");
  expect({
    title: h.screen().includes("Save user settings"),
    stored: h.store.load(),
  }).toStrictEqual({ title: true, stored: h.source });
  h.choose("Save & use");
  const saved = h.store.load();
  expect({
    base: saved.base.document,
    userExists: saved.userExists,
    document: saved.loaded.document,
  }).toStrictEqual({
    base: { preset: "rich" },
    userExists: true,
    document: { preset: "compact" },
  });
});
