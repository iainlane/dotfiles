import { expect, it } from "vitest";
import { readStatus } from "../src/status.ts";
import { createSnapshot } from "../src/state.ts";
import { layoutFooter } from "../src/render.ts";
import { explainSegment, configurationLines } from "../src/explanation.ts";
import { loadSettings } from "../src/settings.ts";

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
  expect(frame.bottom.text).not.toContain("plan mode on");
  expect(frame.bottom.text).toContain("◇ legacy: plan: implementation");
  expect(explainSegment(frame, "planning")).toContain("Symbols: [P]");
  expect(configurationLines(settings)).toContain(
    'Symbols: {"planning":"[P]","default":"◇","__proto__":"@"}',
  );
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
  expect(explainSegment(frame, "statuses")).toContain("Symbols: __proto__: @");
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
      legend: explainSegment(frame, "statuses").find((line) =>
        line.startsWith("Symbols:"),
      ),
    }).toStrictEqual({
      values: ["L legacy: working"],
      legend: "Symbols: legacy: L",
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
  expect(explainSegment(frame, "planning")).toContain("Symbols: P");
  expect(explainSegment(frame, "statuses")).toContain("Symbols: +");
});
