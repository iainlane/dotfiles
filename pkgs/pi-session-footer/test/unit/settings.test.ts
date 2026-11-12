import { expect, it } from "vitest";
import {
  DEFAULT_SYMBOLS,
  loadSettings,
  PRESETS,
  resolveSettings,
} from "#footer/configuration/settings.ts";
import {
  DuplicateWidgetError,
  ExpectedObjectError,
  ExpectedWidgetArrayError,
  InvalidInlineTextError,
  InvalidPlacementError,
  UnknownPresetError,
  UnknownSettingError,
} from "#footer/configuration/settings-errors.ts";
import { thrown } from "#test/support/thrown.ts";

it.each(["rich", "compact", "minimal", "workflow"] as const)(
  "resolves %s without sharing mutable arrays",
  (preset) => {
    expect(resolveSettings({ preset })).toStrictEqual({
      preset,
      regions: PRESETS[preset],
      overridden: [],
      symbols: DEFAULT_SYMBOLS,
      separators: {},
      persistence: "local",
    });
  },
);
it("replaces only explicit regions and permits cross-region repetition", () => {
  expect(
    resolveSettings({ "top-left": [], "bottom-left": ["context"] }),
  ).toStrictEqual({
    preset: "rich",
    regions: { ...PRESETS.rich, "top-left": [], "bottom-left": ["context"] },
    overridden: ["top-left", "bottom-left"],
    symbols: DEFAULT_SYMBOLS,
    separators: {},
    persistence: "local",
  });
});
it.each([
  { value: null, error: new ExpectedObjectError("settings") },
  { value: [], error: new ExpectedObjectError("settings") },
  { value: { preset: "other" }, error: new UnknownPresetError() },
  { value: { extra: true }, error: new UnknownSettingError("settings.extra") },
  {
    value: { "top-left": "model" },
    error: new ExpectedWidgetArrayError("top-left"),
  },
  {
    value: { "top-left": ["missing"] },
    error: new InvalidPlacementError("top-left[0]"),
  },
  {
    value: { "top-left": ["model", "model"] },
    error: new DuplicateWidgetError("top-left"),
  },
])("rejects invalid configuration atomically: $value", ({ value, error }) => {
  expect(thrown(() => resolveSettings(value))).toStrictEqual(error);
});
it.each(["{", '{"preset":"bad"}'])(
  "retains a safe actionable diagnostic for %s",
  (content) => {
    const result = loadSettings(() => content, "/agent/session-footer.json");
    expect({
      ...result,
      diagnostic: Boolean(
        result.diagnostic?.includes("/agent/session-footer.json"),
      ),
    }).toStrictEqual({
      ...resolveSettings({}),
      path: "/agent/session-footer.json",
      source: "fallback",
      diagnostic: true,
      document: {},
    });
  },
);
it("uses the default when absent and falls back when unreadable", () => {
  expect(
    loadSettings((): undefined => {}, "/agent/session-footer.json"),
  ).toStrictEqual({
    ...resolveSettings({}),
    path: "/agent/session-footer.json",
    source: "default",
    diagnostic: undefined,
    document: {},
  });
  expect(
    loadSettings(() => {
      throw new Error("secret contents");
    }, "/agent/session-footer.json").diagnostic,
  ).toBe(
    "Cannot load /agent/session-footer.json. Check file permissions and JSON syntax; using built-in rich. See /footer config.",
  );
});

it.each(["", " ", "\n", "\u001B[31mP", "123456789", "界界界界界", "x\u200By"])(
  "rejects unsafe or oversized symbols atomically: %j",
  (symbol) => {
    const settings = loadSettings(
      () =>
        JSON.stringify({ preset: "compact", symbols: { planning: symbol } }),
      "/settings",
    );
    expect(settings.source).toBe("fallback");
    expect(settings.preset).toBe("rich");
  },
);
it("accepts independently styled placements without expanding default widgets", () => {
  const placement = {
    id: "git",
    colour: "text",
    symbol: { alias: "git", colour: "accent" },
    roles: { staged: { symbol: { text: "+", colour: "success" } } },
  };
  const settings = resolveSettings({
    "top-left": ["model", placement],
    "bottom-right": ["git"],
  });
  expect(settings.regions).toStrictEqual({
    ...PRESETS.rich,
    "top-left": ["model", placement],
    "bottom-right": ["git"],
  });
});

it.each([
  {},
  { widgets: " · " },
  { regions: " │ " },
  { widgets: "", regions: "" },
])("accepts optional expanded separators %j", (separators) => {
  expect(resolveSettings({ separators }).separators).toStrictEqual(separators);
});
it.each([
  { separators: " · ", error: new ExpectedObjectError("separators") },
  { separators: null, error: new ExpectedObjectError("separators") },
  {
    separators: { widgets: "\n" },
    error: new InvalidInlineTextError("separators.widgets"),
  },
  {
    separators: { extra: "x" },
    error: new UnknownSettingError("separators.extra"),
  },
])("rejects invalid separators $separators", ({ separators, error }) => {
  expect(thrown(() => resolveSettings({ separators }))).toStrictEqual(error);
});
it.each(["local", "session"])("resolves persistence %s", (persistence) => {
  expect(resolveSettings({ persistence }).persistence).toBe(persistence);
});
it("rejects duplicate widget IDs across string and object forms", () => {
  expect(
    thrown(() =>
      resolveSettings({
        "top-left": ["git", { id: "git", colour: "accent" }],
      }),
    ),
  ).toStrictEqual(new DuplicateWidgetError("top-left"));
});
it("retains only explicit document settings and normalises empty appearance", () => {
  const loaded = loadSettings(
    () =>
      JSON.stringify({
        preset: "compact",
        "top-left": ["model", { id: "git", symbol: {}, roles: {} }],
      }),
    "/agent/session-footer.json",
  );
  expect(loaded.document).toStrictEqual({
    preset: "compact",
    "top-left": ["model", "git"],
  });
});

it.each(["[P]", "≡", "󰁯", "界", "é"])(
  "accepts inline Unicode or ASCII symbols: %s",
  (symbol) => {
    const settings = resolveSettings({ symbols: { planning: symbol } });
    expect(settings.symbols.get("planning")).toBe(symbol);
    expect(settings.symbols.get("default")).toBe("◇");
  },
);
