import { expect, it, vi } from "vitest";
import {
  layoutFooter,
  fitFooterRow,
  completeFooterFrame,
} from "#footer/rendering/render.ts";
import { resolveSettings } from "#footer/configuration/settings.ts";
import { createSnapshot } from "#footer/domain/state.ts";
import { parseGitStatus } from "#footer/integrations/git.ts";
import { visibleWidth } from "@earendil-works/pi-tui";

it.each([
  ["git", "git"],
  [{ alias: "git" }, ""],
] as const)("keeps source symbol strings literal: %j", (symbol, glyph) => {
  const state = createSnapshot(0, "/demo");
  state.statuses = new Map([["source", "message"]]);
  const frame = layoutFooter(
    state,
    { top: 80, bottom: 0 },
    {
      settings: resolveSettings({
        "top-left": [
          { id: "statuses", colour: "text", symbol: { colour: "accent" } },
        ],
        "top-right": [],
        "bottom-left": [],
        "bottom-right": [],
        symbols: {
          source:
            typeof symbol === "string"
              ? symbol
              : { ...symbol, colour: "success" },
        },
      }),
    },
  );
  const part = frame.placements[0]?.parts[0];
  expect({
    value: part?.value,
    symbols: part?.symbols,
    textColour: part?.runs[1]?.colour,
  }).toStrictEqual({
    value: `${glyph} source: message`,
    symbols: [{ role: "message", value: glyph, colour: "accent" }],
    textColour: "text",
  });
});
it("reduces custom separator overhead before omitting useful readings", () => {
  const state = createSnapshot(0, "/demo");
  state.diagnostics.receive({
    v: 1,
    cwd: state.cwd,
    seq: 1,
    files: [
      {
        path: "file.ts",
        diagnostics: [{ severity: "error", message: "Failure" }],
      },
    ],
  });
  const frame = layoutFooter(
    state,
    { top: 8, bottom: 0 },
    {
      settings: resolveSettings({
        "top-left": ["diagnostics", "input"],
        "top-right": [],
        "bottom-left": [],
        "bottom-right": [],
        separators: { widgets: "XXXXXXXX" },
      }),
    },
  );
  expect({
    value: frame.top.text,
    choices: frame.decisions.map(({ decision }) => decision),
  }).toStrictEqual({ value: "⊗1 ⚠0 ↑0", choices: ["full", "full"] });
});
it("observes diagnostics once across repeated independently styled placements", () => {
  const state = createSnapshot(0, "/demo");
  state.diagnostics.receive({
    v: 1,
    cwd: state.cwd,
    seq: 1,
    files: [
      {
        path: "file.ts",
        diagnostics: [{ severity: "error", message: "Failure" }],
      },
    ],
  });
  const summary = vi.spyOn(state.diagnostics, "summary");
  const frame = layoutFooter(
    state,
    { top: 80, bottom: 80 },
    {
      settings: resolveSettings({
        "top-left": ["diagnostics"],
        "top-right": [],
        "bottom-left": [
          { id: "diagnostics", roles: { error: { symbol: "E" } } },
        ],
        "bottom-right": [],
      }),
    },
  );
  expect({
    calls: summary.mock.calls,
    values: frame.placements.map(({ display }) => display),
  }).toStrictEqual({ calls: [[]], values: ["⊗1 ⚠0", "E1 ⚠0"] });
});
it.each([
  [{ widgets: "" }, " main↑0", "↓0", false],
  [{ widgets: "  " }, " main  ↑0", "↓0", false],
  [{ regions: "界" }, " main  ↑0", "↓0", true],
  [{ widgets: "", regions: "" }, " main↑0", "↓0", false],
] as const)(
  "preserves literal separator settings %j",
  (separators, left, right, marker) => {
    const state = createSnapshot(0, "/demo");
    state.git = parseGitStatus("# branch.head main", 0);
    const frame = layoutFooter(
      state,
      { top: 80, bottom: 0 },
      {
        settings: resolveSettings({
          "top-left": ["git", "input"],
          "top-right": ["output"],
          "bottom-left": [],
          "bottom-right": [],
          separators,
        }),
      },
    );
    expect({
      left: frame.top.left,
      right: frame.top.right,
      marker: frame.top.text.includes("界"),
      width: visibleWidth(frame.top.text),
    }).toStrictEqual({ left, right, marker, width: 80 });
  },
);
it("captures the styled gauge without overwriting the region separator", () => {
  const state = createSnapshot(0, "/demo");
  state.context = { tokens: 50_000, capacity: 100_000, percent: 50 };
  state.usage.cost = 1;
  const frame = layoutFooter(
    state,
    { top: 80, bottom: 0 },
    {
      settings: resolveSettings({
        "top-left": [
          {
            id: "context",
            roles: {
              "gauge-used": { symbol: { text: "#", colour: "accent" } },
              "gauge-free": { symbol: "-" },
            },
          },
        ],
        "top-right": ["cost"],
        "bottom-left": [],
        "bottom-right": [],
        separators: { regions: " │ " },
      }),
    },
  );
  const gauge = frame.placements[0]?.gauge;
  expect({
    value: gauge?.value,
    symbols: gauge?.symbols,
    separator: frame.top.text.includes(" │ "),
  }).toStrictEqual({
    value: "#".repeat(29) + "-".repeat(28),
    symbols: [
      ...Array.from({ length: 29 }, () => ({
        role: "gauge-used",
        value: "#",
        colour: "accent",
      })),
      ...Array.from({ length: 28 }, () => ({
        role: "gauge-free",
        value: "-",
        colour: "border",
      })),
    ],
    separator: true,
  });
});
it("captures the final bottom budget without losing the top observations", () => {
  const state = createSnapshot(0, "/demo");
  state.git = parseGitStatus("# branch.head main", 0);
  const settings = resolveSettings({
    "top-left": ["git"],
    "top-right": [],
    "bottom-left": [],
    "bottom-right": [{ id: "git", symbol: "[G]" }],
  });
  const pending = layoutFooter(state, { top: 40, bottom: 0 }, { settings });
  const complete = completeFooterFrame(
    pending,
    fitFooterRow(pending, settings, { placement: "bottom", width: 30 }),
  );
  expect(
    complete.placements.map(({ id, region, display, budget }) => ({
      id,
      region,
      display,
      budget,
    })),
  ).toStrictEqual([
    { id: "git", region: "top-left", display: " main", budget: 40 },
    { id: "git", region: "bottom-right", display: "[G] main", budget: 30 },
  ]);
});
it("styles repeated placements independently before fitting", () => {
  const state = createSnapshot(0, "/demo");
  state.git = { ...parseGitStatus("# branch.head main", 0), staged: 1 };
  const frame = layoutFooter(
    state,
    { top: 80, bottom: 80 },
    {
      settings: resolveSettings({
        "top-left": [
          { id: "git", symbol: "[G]", roles: { staged: { symbol: "+" } } },
        ],
        "top-right": [],
        "bottom-left": [],
        "bottom-right": ["git"],
      }),
    },
  );
  expect(
    frame.decisions.map(({ region, display }) => ({ region, display })),
  ).toStrictEqual([
    { region: "top-left", display: "[G] main +1" },
    { region: "bottom-right", display: " main ✚1" },
  ]);
});
it("separates placements without separating independent children", () => {
  const state = createSnapshot(0, "/demo");
  state.model = "demo";
  state.reasoning = true;
  state.thinking = "high";
  state.statuses = new Map([
    ["first", "one"],
    ["second", "two"],
  ]);
  state.usage.latestHit = 25;
  const frame = layoutFooter(
    state,
    { top: 100, bottom: 0 },
    {
      settings: resolveSettings({
        "top-left": ["statuses", "thinking"],
        "top-right": ["cache"],
        "bottom-left": [],
        "bottom-right": [],
        separators: { widgets: " · ", regions: " │ " },
      }),
    },
  );
  expect({
    left: frame.top.left,
    right: frame.top.right,
    markerCount: frame.top.text.split(" │ ").length - 1,
  }).toStrictEqual({
    left: "◇ first: one ◇ second: two · ◒ high",
    right: " 25.0%",
    markerCount: 1,
  });
});
it.each([1, 2, 5, 10, 20])("fits expanded decoration at width %i", (width) => {
  const state = createSnapshot(0, "/demo");
  state.model = "some-long-model";
  state.usage.latestHit = 25;
  const frame = layoutFooter(
    state,
    { top: width, bottom: 0 },
    {
      settings: resolveSettings({
        "top-left": [{ id: "model", symbol: "[MODEL]" }],
        "top-right": ["cache"],
        "bottom-left": [],
        "bottom-right": [],
        separators: { widgets: " · ", regions: " │ " },
      }),
    },
  );
  expect(visibleWidth(frame.top.text)).toBeLessThanOrEqual(width);
});
function singlePartReading(id: "git" | "model", value: string) {
  return {
    id,
    state: "available" as const,
    reason: "",
    details: [],
    parts: [
      {
        key: id,
        variants: [value],
        tokens: [[{ kind: "text" as const, value }]],
        priority: 1,
      },
    ],
  };
}
it.each([
  { width: 16, parts: ["aaaaaaaaaa", "bb…"], used: 16 },
  { width: 11, parts: ["aaaaaaaaaa", ""], used: 10 },
])(
  "truncates the last visible part to the width that remains: $width",
  ({ width, parts, used }) => {
    const pending = layoutFooter(
      createSnapshot(0, "/demo"),
      { top: 80, bottom: 0 },
      { settings: resolveSettings({}) },
    );
    const observation = {
      ...pending,
      readings: {
        ...pending.readings,
        git: singlePartReading("git", "a".repeat(10)),
        model: singlePartReading("model", "b".repeat(10)),
      },
    };
    const settings = resolveSettings({
      "top-left": ["git", "model"],
      "top-right": [],
    });
    const fitted = fitFooterRow(observation, settings, {
      placement: "top",
      width,
    });
    expect({
      used: visibleWidth(fitted.row.text),
      parts: fitted.placements.map((placement) => placement.parts[0]?.value),
    }).toStrictEqual({ used, parts });
  },
);
