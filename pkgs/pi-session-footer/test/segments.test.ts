import { expect, it } from "vitest";
import { visibleWidth } from "@earendil-works/pi-tui";
import { createSnapshot } from "../src/state.ts";
import { layoutFooter } from "../src/render.ts";
import { REGIONS, resolveSettings } from "../src/settings.ts";

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
  expect(fit({}).top.text).toContain("━");
  expect(fit({ "top-right": [] }).top.text).not.toContain("━");
  state.context.percent = null;
  expect(fit({}).top.text).not.toContain("━");
});
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
    expect({
      top: frame.top.text.includes("━"),
      bottom: frame.bottom.text.includes("━"),
    }).toStrictEqual({
      top: region.startsWith("top-"),
      bottom: region.startsWith("bottom-"),
    });
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
    disabled: frame.disabled.includes("activity"),
  }).toStrictEqual({ top: " /work", bottom: "", disabled: true });
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
