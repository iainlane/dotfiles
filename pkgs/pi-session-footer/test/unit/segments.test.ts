import { expect, it } from "vitest";
import { visibleWidth } from "@earendil-works/pi-tui";
import { createSnapshot } from "#footer/domain/state.ts";
import { layoutFooter } from "#test/support/layout.ts";
import { REGIONS, resolveSettings } from "#footer/configuration/settings.ts";

it("records each repeated placement without retaining mutable readings", () => {
  const state = createSnapshot(1000, "/work");
  state.context.percent = 0;
  const frame = layoutFooter(
    state,
    { top: 80, bottom: 70 },
    { settings: resolveSettings({ "bottom-left": ["context"] }) },
  );
  state.context.percent = 99;
  expect(
    frame.decisions
      .filter((item) => item.id === "context")
      .map(({ region, display, decision }) => ({ region, display, decision })),
  ).toStrictEqual([
    { region: "top-right", display: "◫ 0.0%", decision: "full" },
    { region: "bottom-left", display: "◫ 0.0%", decision: "full" },
  ]);
});
it("uses spare top-border space as a gauge only for displayed known context", () => {
  const state = createSnapshot(1000, "/work");
  state.context.percent = 50;
  const fit = (settings: unknown) =>
    layoutFooter(
      state,
      { top: 80, bottom: 80 },
      { settings: resolveSettings(settings) },
    );
  const known = fit({}).top.text;
  const withoutRight = fit({ "top-right": [] }).top.text;
  state.context.percent = null;
  const unknown = fit({}).top.text;
  expect({ known, withoutRight, unknown }).toStrictEqual({
    known:
      " /work ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━───────────────────────────────  ◫ 50.0%",
    withoutRight: " /work",
    unknown: " /work",
  });
});
const expectedRegion: Record<string, unknown> = {
  "top-left": {
    top: "◫ 50.0% ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━─────────────────────────────────── ",
    bottom: "",
  },
  "top-right": {
    top: " ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━──────────────────────────────────  ◫ 50.0%",
    bottom: "",
  },
  "bottom-left": {
    top: "",
    bottom:
      "◫ 50.0% ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━─────────────────────────────────── ",
  },
  "bottom-right": {
    top: "",
    bottom:
      " ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━──────────────────────────────────  ◫ 50.0%",
  },
};
it.each(REGIONS)(
  "keeps the context gauge with its configured %s occurrence",
  (region) => {
    const state = createSnapshot(1000, "/work");
    state.context.percent = 50;
    const settings = resolveSettings({
      "top-left": [],
      "top-right": [],
      "bottom-left": [],
      "bottom-right": [],
      [region]: ["context"],
    });
    const frame = layoutFooter(state, { top: 80, bottom: 80 }, { settings });
    const rows = { top: frame.top.text, bottom: frame.bottom.text };
    expect(rows).toStrictEqual(expectedRegion[region]);
  },
);
it("does not reinsert excluded warnings or idle placeholders", () => {
  const state = createSnapshot(1000, "/work");
  state.activity.outcome = "failed";
  const frame = layoutFooter(
    state,
    { top: 80, bottom: 80 },
    { settings: resolveSettings({ preset: "minimal" }) },
  );
  expect({
    top: frame.top.text,
    bottom: frame.bottom.text,
    disabled: frame.disabled,
  }).toStrictEqual({
    top: " /work",
    bottom: "",
    disabled: [
      "model",
      "thinking",
      "tier",
      "pr",
      "activity",
      "diagnostics",
      "tasks",
      "blocked",
      "agents",
      "agent-context",
      "agent-spent",
      "pending",
      "planning",
      "ci",
      "reviews",
      "statuses",
      "quota",
      "cache",
      "cost",
      "auxiliary-cost",
      "age",
      "input",
      "output",
      "cache-read",
      "cache-write",
      "run-duration",
      "active-duration",
      "compaction-duration",
    ],
  });
});
it.each([1, 12, 35, 80, 200])("records bounded region fits at %i", (width) => {
  const state = createSnapshot(1000, "/界/é-long-directory");
  state.model = "long-model-name";
  state.provider = "provider";
  state.activity.outcome = "failed";
  const frame = layoutFooter(
    state,
    { top: width, bottom: width },
    { settings: resolveSettings({}) },
  );
  expect(
    frame.decisions.every((entry) =>
      ["full", "shortened", "omitted", "truncated", "suppressed"].includes(
        entry.decision,
      ),
    ),
  ).toBe(true);
  expect({
    budget: frame.top.width,
    topFits: visibleWidth(frame.top.text) <= width,
    bottomFits: visibleWidth(frame.bottom.text) <= width,
  }).toStrictEqual({ budget: width, topFits: true, bottomFits: true });
});
