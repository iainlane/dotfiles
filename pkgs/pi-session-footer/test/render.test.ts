import { expect, it, vi } from "vitest";
import { visibleWidth } from "@earendil-works/pi-tui";
import { createSnapshot } from "../src/state.ts";
import { layoutFooter, renderFooter } from "../src/render.ts";
import { resolveSettings } from "../src/settings.ts";
import { readQuota } from "../src/quota.ts";
import { parseGitStatus } from "../src/git.ts";
import { readSegments, SEGMENTS } from "../src/segments.ts";
import type { SegmentId } from "../src/settings.ts";
const now = Date.UTC(2026, 9, 20, 12);
function fixture() {
  const state = createSnapshot(now - 3_000_000, "/Users/test/dev/dotfiles");
  Object.assign(state, {
    now,
    model: "gpt-6-astra",
    provider: "openai",
    thinking: "high",
    reasoning: true,
  });
  state.context = { tokens: 66_000, capacity: 272_000, percent: 24.3 };
  state.quota = readQuota({
    state: {
      provider: "codex",
      usage: {
        lastSuccessAt: now,
        windows: [
          {
            label: "5h",
            usedPercent: 15,
            resetAt: new Date(now + 7_200_000).toISOString(),
          },
          {
            label: "Week",
            usedPercent: 18,
            resetAt: new Date(now + 259_200_000).toISOString(),
          },
        ],
      },
    },
  });
  return state;
}
it.each([false, true])(
  "fits extension messages independently with a known LSP failure=%s",
  (failure) => {
    const state = fixture();
    state.activity.waiting = !failure;
    const statuses = new Map([["other", "x".repeat(100)]]);

    if (failure) {
      statuses.set("pi-lens-lsp", "LSP Failed");
    }

    state.statuses = statuses;

    const frame = layoutFooter(
      state,
      { top: 0, bottom: 40 },
      {
        settings: resolveSettings({
          "top-left": [],
          "top-right": [],
          "bottom-left": ["activity", "statuses"],
          "bottom-right": [],
        }),
      },
    );

    expect(
      frame.decisions.map(({ id, child, decision }) => ({
        id,
        child,
        decision,
      })),
    ).toStrictEqual([
      {
        id: "activity",
        child: "activity",
        decision: failure ? "suppressed" : "full",
      },
      { id: "statuses", child: "other", decision: "omitted" },
      ...(failure
        ? [{ id: "statuses", child: "pi-lens-lsp", decision: "full" }]
        : []),
    ]);
  },
);
it.each<[SegmentId, string]>([
  ["model", " openai/gpt-6-astra"],
  ["thinking", "◒ high"],
  ["directory", " /Users/test/dev/dotfiles"],
  ["git", " main ✚1 ✎2 ?3 ↑4 ↓5"],
  ["context", "◫ 24.3%/272k"],
  ["tasks", "☑ 0/1 Verify layout"],
  ["blocked", " 1"],
  ["agents", " 2 stale"],
  ["pending", " pending"],
  ["planning", "≡ Plan · implementation"],
  ["statuses", "◇ source: actual message"],
  ["quota", "◴ 5h 15% ↻2h"],
  ["cache", " 0.0%"],
  ["auxiliary-cost", " ≈$0.25"],
  ["age", " 50m"],
])(
  "renders %s with its semantic symbol and a matching legend",
  (id, expected) => {
    const state = fixture();
    state.git = {
      ...parseGitStatus("# branch.head main", now),
      staged: 1,
      unstaged: 2,
      untracked: 3,
      ahead: 4,
      behind: 5,
    };
    state.tasks = [
      {
        id: 1,
        subject: "Verify layout",
        activeForm: undefined,
        status: "in_progress",
        blockedBy: [2],
      },
    ];
    state.agents = {
      active: 2,
      failed: 1,
      paused: 1,
      incomplete: true,
      stale: true,
      runs: [],
    };
    state.pending = true;
    state.statuses = new Map([
      ["planning", "Plan · implementation"],
      ["source", "actual message"],
    ]);
    state.usage.latestHit = 0;
    state.auxiliaryUsage.cost = 0.25;
    expect({
      value: readSegments(state)[id].parts[0]?.variants[0],
      legend: SEGMENTS[id].symbols.includes(expected.split(" ")[0] ?? ""),
    }).toStrictEqual({ value: expected, legend: true });
  },
);
it("fits delegation warnings independently from exact active children", () => {
  const state = fixture();
  state.agents = {
    active: 1,
    failed: 1,
    paused: 0,
    incomplete: true,
    stale: true,
    runs: [],
  };
  state.diagnostics.receive({
    v: 1,
    cwd: state.cwd,
    seq: 1,
    files: [
      {
        path: "test.ts",
        diagnostics: [{ severity: "error", message: "Error" }],
      },
    ],
  });
  const frame = layoutFooter(
    state,
    { top: 25, bottom: 25 },
    {
      settings: resolveSettings({
        "bottom-left": ["diagnostics", "agents"],
        "bottom-right": [],
      }),
    },
  );
  expect({
    failed: frame.bottom.text.includes("failed 1+ stale"),
    active: frame.bottom.text.includes(" 1 stale"),
    decisions: frame.decisions
      .filter((d) => d.id === "agents")
      .map(({ child, decision }) => ({ child, decision })),
  }).toStrictEqual({
    failed: true,
    active: false,
    decisions: [
      { child: "active", decision: "omitted" },
      { child: "failed", decision: "full" },
    ],
  });
});
it.each([
  ["off", "⊘"],
  ["minimal", "○"],
  ["low", "◔"],
  ["medium", "◑"],
  ["high", "◒"],
  ["xhigh", "◕"],
  ["max", "◉"],
])(
  "offers full and compact native thinking variants for %s",
  (level, glyph) => {
    const state = fixture();
    state.thinking = level;
    expect(readSegments(state).thinking.parts[0]?.variants).toStrictEqual(
      level === "off" ? [glyph, ""] : [`${glyph} ${level}`, glyph, ""],
    );
  },
);
it.each(["", "provider"])(
  "keeps model shortening before omission with provider '%s'",
  (provider) => {
    const state = fixture();
    state.provider = provider;
    state.model = "a-long-model-name-for-fitting";
    const frame = layoutFooter(
      state,
      { top: 15, bottom: 0 },
      {
        settings: resolveSettings({
          "top-left": ["model"],
          "top-right": [],
          "bottom-left": [],
          "bottom-right": [],
        }),
      },
    );
    expect(
      frame.decisions.map(({ id, decision }) => ({ id, decision })),
    ).toStrictEqual([{ id: "model", decision: "shortened" }]);
  },
);
it("retains source failure and provenance without fabricating missing readings", () => {
  const state = createSnapshot(now, "/work");
  state.gitError = "permission denied";
  state.quota = readQuota({
    state: {
      provider: "codex",
      usage: { error: { code: "AUTH_FAILED" }, credentialSource: "fixture" },
    },
  });
  const readings = readSegments(state);
  expect({
    git: readings.git.parts[0]?.variants[0],
    quota: readings.quota.parts[0]?.variants[0],
    source: readings.quota.details.some((line) => line.includes("fixture")),
  }).toStrictEqual({
    git: " ⚠ permission denied",
    quota: "◴ ⚠ AUTH_FAILED",
    source: true,
  });
  state.quota = fixture().quota;
  state.now += 300_001;
  expect({
    state: readSegments(state).quota.state,
    expired: readSegments(state).quota.reason,
    retained: readSegments(state).quota.details.some((line) =>
      line.includes("5h"),
    ),
  }).toStrictEqual({
    state: "unavailable",
    expired: "Quota percentages expired",
    retained: true,
  });
});
it.each([0, 1, 2, 10, 30, 60, 80, 120, 180, 240])(
  "fits %i columns with Unicode and semantic omission",
  (width) => {
    const state = fixture();
    state.cwd = "/work/界界/é-feature-with-a-long-name";
    state.activity.outcome = "failed";
    const rows = renderFooter(state, width);
    expect({
      fits: rows.every((line) => visibleWidth(line) <= width),
      generic: rows.some((line) => /status \+\d| \+\d/.test(line)),
    }).toStrictEqual({ fits: true, generic: false });
  },
);
it.each(["rich", "compact", "minimal", "workflow"] as const)(
  "uses configured %s order and no unselected attention",
  (preset) => {
    const state = fixture();
    state.activity.outcome = "failed";
    const frame = layoutFooter(
      state,
      { top: 240, bottom: 240 },
      { settings: resolveSettings({ preset }), home: "/Users/test" },
    );
    expect(
      frame.decisions.filter((d) => d.display).map((d) => [d.region, d.id]),
    ).toStrictEqual([
      ...(preset === "minimal"
        ? [["top-left", "directory"]]
        : [
            ["top-left", "model"],
            ["top-left", "thinking"],
            ["top-left", "directory"],
          ]),
      ["top-right", "context"],
      ...(["rich", "workflow"].includes(preset)
        ? [
            ["bottom-left", "activity"],
            ["bottom-right", "quota"],
            ["bottom-right", "quota"],
          ]
        : []),
      ...(preset === "rich" ? [["bottom-right", "age"]] : []),
    ]);
  },
);
it.each([
  [null, 0, ""],
  [null, 272000, "◫ 272k"],
  [0, 272000, "◫ 0.0%/272k"],
] as const)(
  "distinguishes missing context from true zero: %s/%i",
  (percent, capacity, expected) => {
    const state = createSnapshot(now, "/work");
    state.context = { tokens: null, percent, capacity };
    expect(readSegments(state).context.parts[0]?.variants[0] ?? "").toBe(
      expected,
    );
  },
);
it.each([false, true])("uses native reasoning capability: %s", (reasoning) => {
  const state = fixture();
  state.reasoning = reasoning;
  expect(readSegments(state).thinking.state).toBe(
    reasoning ? "available" : "unavailable",
  );
});
it.each(["off", "minimal", "low", "medium", "high", "xhigh", "max", "unknown"])(
  "uses native semantic thinking colours for %s",
  (thinking) => {
    const state = fixture();
    state.thinking = thinking;
    const fg = vi.fn<(role: string, value: string) => string>(
      (_role, value) => value,
    );
    readSegments(state, { theme: { fg, bold: (s) => s } });
    expect(
      fg.mock.calls.filter(([, value]) => value === thinking),
    ).toStrictEqual([
      [
        thinking === "unknown"
          ? "muted"
          : `thinking${thinking[0]?.toUpperCase()}${thinking.slice(1)}`,
        thinking,
      ],
    ]);
  },
);
it.each([
  ["/Users/test", "~"],
  ["/Users/test/dev", "~/dev"],
  ["/Users/test-other", "/Users/test-other"],
  ["/界/é", "/界/é"],
])("abbreviates only actual home %s", (cwd, expected) => {
  const state = fixture();
  state.cwd = cwd;
  expect(
    readSegments(state, { home: "/Users/test" }).directory.parts[0]
      ?.variants[0],
  ).toBe(` ${expected}`);
});
it.each([
  { changes: {}, role: "success" },
  { changes: { staged: 1 }, role: "warning" },
  { changes: { unstaged: 1 }, role: "warning" },
  { changes: { conflicts: 1 }, role: "error" },
  { changes: { stale: true }, role: "dim" },
])("preserves semantic Git colours: $role", ({ changes, role }) => {
  const state = fixture();
  state.git = { ...parseGitStatus("# branch.head main", now), ...changes };
  const fg = vi.fn<(role: string, value: string) => string>(
    (_role, value) => value,
  );
  readSegments(state, { theme: { fg, bold: (s) => s } });
  expect(fg.mock.calls.filter(([, value]) => value === "main")).toStrictEqual([
    [role, "main"],
    [role, "main"],
  ]);
});
it("captures actual extension messages rather than integration health or generic counts", () => {
  const state = fixture();
  state.statuses = new Map([
    ["other", "\u001B[31mactual service error"],
    ["pi-lens-lsp", "LSP Failed"],
  ]);
  expect(readSegments(state).statuses).toStrictEqual({
    id: "statuses",
    state: "available",
    reason: "",
    parts: [
      {
        key: "other",
        variants: ["◇ other: actual service error", ""],
        priority: 25,
      },
      {
        key: "pi-lens-lsp",
        variants: ["◇ pi-lens-lsp: LSP Failed", ""],
        priority: 120,
      },
    ],
    details: ["other: actual service error", "pi-lens-lsp: LSP Failed"],
    symbols: "other: ◇; pi-lens-lsp: ◇",
  });
});
it("preserves warnings before routine identity and quota detail", () => {
  const state = fixture();
  state.git = { ...parseGitStatus("# branch.head main", now), conflicts: 1 };
  state.activity.outcome = "failed";
  const frame = layoutFooter(
    state,
    { top: 35, bottom: 35 },
    { settings: resolveSettings({}) },
  );
  expect({
    conflict: frame.top.text.includes("conflicts 1"),
    failed: frame.bottom.text.includes("run failed"),
    countdown: frame.bottom.text.includes("↻2h"),
  }).toStrictEqual({ conflict: true, failed: true, countdown: false });
});
it.each([0, 31000, 300001])(
  "keeps quota freshness and omits expired percentages at age %i",
  (age) => {
    const state = fixture();
    state.now += age;
    const reading = readSegments(state).quota;
    expect({
      state: reading.state,
      stale: reading.parts[0]?.variants[0]?.includes("stale") ?? false,
    }).toStrictEqual({
      state: age > 300000 ? "unavailable" : "available",
      stale: age === 31000,
    });
  },
);
it("records child-level quota fits and restores countdowns on widening", () => {
  const state = fixture();
  const fit = (width: number) =>
    layoutFooter(
      state,
      { top: width, bottom: width },
      { settings: resolveSettings({}) },
    );
  const narrow = fit(32);
  expect(
    narrow.decisions
      .filter((d) => d.id === "quota")
      .map(({ child, decision }) => ({ child, decision })),
  ).toStrictEqual([
    { child: "0:5h", decision: "shortened" },
    { child: "1:Week", decision: "shortened" },
  ]);
  expect(fit(240).bottom.text).toContain("↻2h");
});
it("retains zero measurements but suppresses initial idle cost and age", () => {
  const state = createSnapshot(now, "/work");
  expect([
    readSegments(state).input.parts[0]?.variants[0],
    readSegments(state).cost.state,
    readSegments(state).age.state,
  ]).toStrictEqual(["↑0", "idle", "idle"]);
  state.usage.input = 1;
  expect(readSegments(state).cost.parts[0]?.variants[0]).toBe("≈$0.00");
  state.usage.costFromProvider = true;
  expect(readSegments(state).cost.parts[0]?.variants[0]).toBe("$0.00");
});
