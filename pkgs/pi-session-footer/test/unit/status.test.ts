import { expect, it } from "vitest";
import { readStatus } from "#footer/domain/status.ts";
import { createSnapshot } from "#footer/domain/state.ts";
import { layoutFooter } from "#test/support/layout.ts";
import { CapturedFooter } from "#footer/ui/inspection/explanation.ts";
import { loadSettings } from "#footer/configuration/settings.ts";

const snapshot = {
  version: 1,
  source: "planning",
  sessionId: "session-one",
  active: true,
};
it.each([
  null,
  {},
  { ...snapshot, version: 2 },
  { ...snapshot, active: "yes" },
  { ...snapshot, source: "" },
  { ...snapshot, source: "bad\nsource" },
  { ...snapshot, sessionId: "" },
  { ...snapshot, text: 42 },
])("rejects malformed cooperative snapshots: %j", (raw) => {
  expect(readStatus(raw)).toBeUndefined();
});
it("copies and sanitises variable details, without interpreting display labels", () => {
  const raw = {
    ...snapshot,
    text: "\u001B[31mplan: implementation\nnext\u0007",
  };
  const result = readStatus(raw);
  raw.text = "changed";
  expect(result).toStrictEqual({
    ...snapshot,
    text: "plan: implementation next",
  });
  expect(Object.isFrozen(result)).toBe(true);
});
it("renders semantic planning with the configured icon and no native duplicate", () => {
  const state = createSnapshot(1000, "/work");
  const settings = loadSettings(
    () => '{"symbols":{"planning":"[P]","__proto__":"@"}}',
    "/settings",
  );
  state.statuses = new Map([
    ["planning", "plan mode on"],
    ["legacy", "plan: implementation"],
  ]);
  state.cooperativeStatuses = new Map([
    ["planning", { ...snapshot, version: 1 }],
  ]);
  const frame = layoutFooter(state, { top: 200, bottom: 200 }, { settings });
  expect(frame.readings.planning.parts[0]?.variants[0]).toBe("[P]");
  const legacy = {
    bottom: frame.bottom.text,
    planning: new CapturedFooter(frame).technical("planning"),
  };
  expect(legacy).toStrictEqual({
    bottom: "[P]  ◇ legacy: plan: implementation",
    planning: [
      "Captured: 1970-01-01T00:00:01.000Z",
      "Owner: composer",
      "Usable columns: top 200, bottom 200",
      "Source symbols: [P]",
      "Bottom left: 200 columns",
      "Appearance: {}",
      "planning: variant 1, priority 80",
      'Symbols: [{"value":"[P]","colour":"accent"}]',
      "Bottom left · planning: full",
      "Default priority: 80. Full, shortened where supported, then omitted for width.",
    ],
  });
  expect(Object.fromEntries(settings.symbols)).toStrictEqual({
    planning: "[P]",
    default: "◇",
    ["__proto__"]: "@",
  });
  state.cooperativeStatuses = new Map([
    ["planning", { ...snapshot, version: 1, active: false }],
  ]);
  expect(
    layoutFooter(state, { top: 200, bottom: 200 }, { settings }).readings
      .planning.state,
  ).toBe("idle");
  expect(frame.readings.planning.parts[0]?.variants[0]).toBe("[P]");
});
it("supports arbitrary cooperative source IDs, inactive suppression and detail updates", () => {
  const state = createSnapshot(1000, "/work");
  const settings = loadSettings(
    () => '{"symbols":{"default":"+","__proto__":"@"}}',
    "/settings",
  );
  state.statuses = new Map([
    ["__proto__", "stale"],
    ["other", "stale"],
  ]);
  state.cooperativeStatuses = new Map([
    [
      "__proto__",
      { ...snapshot, version: 1, source: "__proto__", text: "reviewing" },
    ],
    ["other", { ...snapshot, version: 1, source: "other", active: false }],
  ]);
  const frame = layoutFooter(state, { top: 200, bottom: 200 }, { settings });
  expect(
    frame.readings.statuses.parts.map((part) => part.variants[0]),
  ).toStrictEqual(["@ reviewing"]);
  expect(new CapturedFooter(frame).technical("statuses")).toStrictEqual([
    "Captured: 1970-01-01T00:00:01.000Z",
    "Owner: composer",
    "Usable columns: top 200, bottom 200",
    "Source symbols: __proto__: @",
    "Bottom left: 200 columns",
    "Appearance: {}",
    "__proto__: variant 1, priority 25",
    'Symbols: [{"role":"message","value":"@","colour":"dim"}]',
    "Bottom left · __proto__: full",
    "__proto__: reviewing",
    "Default priority: 25. Full, shortened where supported, then omitted for width.",
  ]);
});
it.each(["legacy", "default"])(
  "uses the %s symbol override for a native source and its captured legend",
  (configured) => {
    const state = createSnapshot(1000, "/work");
    const settings = loadSettings(
      () => JSON.stringify({ symbols: { [configured]: "L" } }),
      "/settings",
    );
    state.statuses = new Map([["legacy", "working"]]);
    const frame = layoutFooter(state, { top: 200, bottom: 200 }, { settings });

    expect({
      values: frame.readings.statuses.parts.map((part) => part.variants[0]),
      legend: new CapturedFooter(frame)
        .technical("statuses")
        .find((line) => line.startsWith("Source symbols:")),
    }).toStrictEqual({
      values: ["L legacy: working"],
      legend: "Source symbols: legacy: L",
    });
  },
);
it("explains effective symbols even when their readings are unavailable", () => {
  const state = createSnapshot(1000, "/work");
  const settings = loadSettings(
    () => '{"symbols":{"planning":"P","default":"+"}}',
    "/settings",
  );
  const frame = layoutFooter(state, { top: 200, bottom: 200 }, { settings });
  const captured = new CapturedFooter(frame);
  const technical = {
    planning: captured.technical("planning"),
    statuses: captured.technical("statuses"),
  };
  expect(technical).toStrictEqual({
    planning: [
      "Captured: 1970-01-01T00:00:01.000Z",
      "Owner: composer",
      "Usable columns: top 200, bottom 200",
      "Source symbols: P",
      "Bottom left: 200 columns",
      "Appearance: {}",
      "Bottom left · planning: suppressed · unavailable: No planning publication",
      "Default priority: 80. Full, shortened where supported, then omitted for width.",
    ],
    statuses: [
      "Captured: 1970-01-01T00:00:01.000Z",
      "Owner: composer",
      "Usable columns: top 200, bottom 200",
      "Source symbols: +",
      "Bottom left: 200 columns",
      "Appearance: {}",
      "Bottom left · statuses: suppressed · unavailable: No other extension messages published",
      "Default priority: 25. Full, shortened where supported, then omitted for width.",
    ],
  });
});
