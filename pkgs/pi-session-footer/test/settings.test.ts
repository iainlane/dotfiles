import { expect, it } from "vitest";
import {
  DEFAULT_SYMBOLS,
  loadSettings,
  PRESETS,
  resolveSettings,
} from "../src/settings.ts";

it.each(["rich", "compact", "minimal", "workflow"] as const)(
  "resolves %s without sharing mutable arrays",
  (preset) => {
    expect(resolveSettings({ preset })).toStrictEqual({
      preset,
      regions: PRESETS[preset],
      overridden: [],
      symbols: DEFAULT_SYMBOLS,
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
  });
});
it.each([
  null,
  [],
  { preset: "other" },
  { extra: true },
  { "top-left": "model" },
  { "top-left": ["missing"] },
  { "top-left": ["model", "model"] },
])("rejects invalid configuration atomically: %j", (value) => {
  expect(() => resolveSettings(value)).toThrow(/Expected|Unknown/);
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
  });
  expect(
    loadSettings(() => {
      throw new Error("secret contents");
    }, "/agent/session-footer.json").diagnostic,
  ).toBe(
    "Cannot load /agent/session-footer.json. Check file permissions and JSON keys, preset and segment IDs; using built-in rich. See /footer config.",
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
it.each(["[P]", "≡", "󰁯", "界", "é"])(
  "accepts inline Unicode or ASCII symbols: %s",
  (symbol) => {
    const settings = resolveSettings({ symbols: { planning: symbol } });
    expect(settings.symbols.get("planning")).toBe(symbol);
    expect(settings.symbols.get("default")).toBe("◇");
  },
);
