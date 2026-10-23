import type { ThemeColor } from "@earendil-works/pi-coding-agent";
import { describe, expect, it, vi } from "vitest";
import { visibleWidth } from "@earendil-works/pi-tui";
import { createSnapshot } from "../src/state.ts";
import { renderFooter } from "../src/render.ts";
import { readQuota } from "../src/quota.ts";
import { parseGitStatus } from "../src/git.ts";

vi.mock("node:os", () => ({ homedir: () => "/Users/test" }));

function aligned(left: string, right: string, width: number): string {
  return (
    left + " ".repeat(width - visibleWidth(left) - visibleWidth(right)) + right
  );
}

const now = Date.UTC(2026, 9, 20, 12);

function fixture(age = 0, error?: string) {
  const state = createSnapshot(now - 3_000_000, "/Users/test/dev/dotfiles");

  state.now = now;
  state.model = "gpt-6-astra";
  state.provider = "openai-codex";
  state.thinking = "high";
  state.context = { tokens: 66_000, capacity: 272_000, percent: 24.3 };
  state.quota = readQuota({
    state: {
      provider: "codex",
      usage: {
        lastSuccessAt: now - age,
        error: error ? { code: error } : undefined,
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

describe("two-row fitting", () => {
  it.each([1, 2, 10, 30, 60, 80, 120, 180, 240])(
    "fits %i columns, including wide and combining text",
    (width) => {
      const state = fixture();

      state.cwd = "/work/界界/é-feature-with-a-long-name";
      state.model = "a-very-long-model-name";
      state.serviceTier = "⚡⚡";
      state.statuses = new Map([["other", "extra \u001b[31mstatus"]]);

      const lines = renderFooter(state, width);

      expect(lines.length).toBeLessThanOrEqual(2);
      expect(lines.every((line) => visibleWidth(line) <= width)).toBe(true);
    },
  );

  it.each([
    { serviceTier: undefined, reasoning: "high" },
    { serviceTier: "", reasoning: "high" },
    { serviceTier: "⚡", reasoning: "high ⚡" },
    { serviceTier: "⚡⚡", reasoning: "high ⚡⚡" },
  ])(
    "groups $reasoning with yellow service-tier bolts",
    ({ serviceTier, reasoning }) => {
      const state = fixture();

      state.serviceTier = serviceTier;

      const roles = colours(state);

      expect({
        lines: renderFooter(state, 240),
        thinkingColour: roles.get("high"),
        serviceTierColour: serviceTier ? roles.get(serviceTier) : undefined,
      }).toStrictEqual({
        lines: [
          aligned(
            `codex/gpt-6-astra  ${reasoning}  ~/dev/dotfiles`,
            " ctx 24.3%/272k",
            240,
          ),
          aligned(
            "",
            " 5h 15% used (2h)  week 18% used (3d)  $0.00  50m",
            240,
          ),
        ],
        thinkingColour: "thinkingHigh",
        serviceTierColour: serviceTier ? "warning" : undefined,
      });
    },
  );

  it("removes countdowns before quota percentages and restores them on widening", () => {
    const state = fixture();
    const wide = renderFooter(state, 180);
    const narrow = renderFooter(state, 35);

    expect(wide.join(" ")).toContain("(2h)");
    expect(narrow.join(" ")).not.toContain("(2h)");
    expect(narrow.join(" ")).toContain("week 18% used");
    expect(renderFooter(state, 180)).toStrictEqual(wide);
  });

  it.each([false, true])(
    "right-aligns both rows with left-hand notices: %s",
    (notice) => {
      const state = fixture();

      if (notice) state.statuses = new Map([["pi-lens-lsp", "LSP Failed"]]);

      const theme = {
        fg: (_role: string, value: string) => `\u001b[35m${value}\u001b[0m`,
        bold: (value: string) => `\u001b[1m${value}\u001b[22m`,
      };

      expect(renderFooter(state, 240, theme).map(visibleWidth)).toStrictEqual([
        240, 240,
      ]);
    },
  );

  it("mirrors separators and preserves right alignment after a notice disappears", () => {
    const state = fixture();

    state.git = parseGitStatus("# branch.head main", now);

    const left = "codex/gpt-6-astra  high  ~/dev/dotfiles   main";
    const context = " ctx 24.3%/272k";
    const quota = " 5h 15% used (2h)  week 18% used (3d)  $0.00  50m";

    state.statuses = new Map([["pi-lens-lsp", "LSP Failed"]]);

    const withNotice = renderFooter(state, 240);

    state.statuses = new Map();

    const withoutNotice = renderFooter(state, 240);

    expect({ withNotice, withoutNotice }).toStrictEqual({
      withNotice: [
        aligned(left, context, 240),
        aligned("LSP Failed", quota, 240),
      ],
      withoutNotice: [aligned(left, context, 240), aligned("", quota, 240)],
    });
  });

  it.each([
    ["/Users/test", "~"],
    ["/Users/test/dev/dotfiles", "~/dev/dotfiles"],
    ["/Users/test-other/dev", "/Users/test-other/dev"],
    ["/work/界/é", "/work/界/é"],
  ])("abbreviates only the actual home directory in %s", (cwd, expected) => {
    const state = fixture();

    state.cwd = cwd;

    expect(renderFooter(state, 240)[0]).toBe(
      aligned(
        `codex/gpt-6-astra  high  ${expected}`,
        " ctx 24.3%/272k",
        240,
      ),
    );
  });

  it.each([
    {
      age: 0,
      error: undefined,
      expected: " 5h 15% used (2h)  week 18% used (3d)",
    },
    {
      age: 1000,
      error: "LIMIT",
      expected: " 5h 15% used (2h) cached  week 18% used (3d) cached",
    },
    {
      age: 31_000,
      error: undefined,
      expected: " 5h 15% used (2h) stale  week 18% used (3d) stale",
    },
    {
      age: 300_001,
      error: undefined,
      expected: " 5h unavailable  week unavailable",
    },
  ])(
    "uses explicit quota freshness at age $age with error $error",
    ({ age, error, expected }) => {
      expect(renderFooter(fixture(age, error), 240)[1]).toBe(
        aligned("", `${expected}  $0.00  50m`, 240),
      );
    },
  );

  it.each(["run failed", "LSP Failed"])(
    "preserves %s before quota percentages at 35 columns",
    (attention) => {
      const state = fixture();

      if (attention === "run failed") state.activity.outcome = "failed";
      else state.statuses = new Map([["pi-lens-lsp", attention]]);

      expect(renderFooter(state, 35)[1]).toBe(
        aligned(`${attention}  +3`, " 5h 15% used", 35),
      );
    },
  );

  it("preserves Git conflicts before routine identity fields", () => {
    const state = fixture();

    state.git = parseGitStatus("# branch.head main", now);
    state.git.conflicts = 1;

    expect(renderFooter(state, 35)[0]).toContain("conflicts 1");
  });

  it("keeps provider-order countdown importance explicit", () => {
    const state = fixture();

    expect(renderFooter(state, 48)[1]).toBe(
      " 5h 15% used (2h)  week 18% used  $0.00  50m",
    );

    state.quota?.windows.reverse();

    expect(renderFooter(state, 48)[1]).toBe(
      " week 18% used (3d)  5h 15% used  $0.00  50m",
    );
  });

  it("uses a compact omission marker without mixing right-hand separators", () => {
    expect(renderFooter(fixture(), 32)[1]).toBe(
      aligned("…", " 5h 15% used  week 18% used", 32),
    );
  });

  it.each([1, 2])("retains two rows without quota at width %i", (width) => {
    const state = fixture();

    state.quota = undefined;

    expect(renderFooter(state, width).map(visibleWidth)).toStrictEqual([
      width,
      width,
    ]);
  });

  it("fits identity independently of quota", () => {
    const state = fixture();

    state.git = parseGitStatus("# branch.head main", now);

    const withQuota = renderFooter(state, 90)[0];

    state.quota = undefined;

    expect(renderFooter(state, 90)[0]).toBe(withQuota);
  });

  it("does not claim healthy diagnostics or a zero context before observation", () => {
    expect(
      renderFooter(createSnapshot(now, "/work"), 80).join(" "),
    ).not.toMatch(/clean|Ready|LSP Active|ctx 0/);
  });
});

function colours(
  state: ReturnType<typeof fixture>,
  bold = (value: string) => value,
) {
  const roles = new Map<string, ThemeColor>();
  const lines = renderFooter(state, 400, {
    fg: (role, value) => {
      roles.set(value, role);

      return value;
    },
    bold,
  });

  expect(lines).toStrictEqual(renderFooter(state, 400));

  return roles;
}

describe("semantic theme colours", () => {
  it("distinguishes identity, activity, measurements and secondary detail", () => {
    const state = fixture();

    state.git = parseGitStatus("# branch.head main", now);
    state.git.staged = 1;
    state.git.unstaged = 2;
    state.tasks = [
      {
        id: 1,
        subject: "Review",
        status: "in_progress",
        activeForm: undefined,
        blockedBy: [],
      },
    ];
    state.agents = {
      active: 2,
      failed: 0,
      paused: 0,
      incomplete: false,
      stale: false,
      runs: [],
    };
    state.activity.tool = "read";
    state.statuses = new Map([["plan-mode", "plan: implementation"]]);
    state.serviceTier = "⚡⚡";

    const bold = vi.fn((value: string) => value);
    const roles = colours(state, bold);

    expect(bold.mock.calls).toStrictEqual([
      ["gpt-6-astra"],
      ["gpt-6-astra"],
      ["gpt-6-astra"],
      ["~/dev/dotfiles"],
      ["dotfiles"],
    ]);
    expect(
      Object.fromEntries(
        [
          "codex/",
          "gpt-6-astra",
          "high",
          "~/dev/dotfiles",
          "main",
          "+1",
          "±2",
          "ctx ",
          "24.3%",
          "/272k",
          "5h",
          "15%",
          " used",
          " (2h)",
          "read",
          "tasks ",
          "0/1",
          " Review",
          "agents ",
          "2",
          "plan: implementation",
          "⚡⚡",
          "$0.00",
          "50m",
          "  ",
          "",
        ].map((value) => [value, roles.get(value)]),
      ),
    ).toStrictEqual({
      "codex/": "muted",
      "gpt-6-astra": "accent",
      high: "thinkingHigh",
      "~/dev/dotfiles": "mdCode",
      main: "warning",
      "+1": "success",
      "±2": "warning",
      "ctx ": "muted",
      "24.3%": "toolTitle",
      "/272k": "dim",
      "5h": "muted",
      "15%": "toolTitle",
      " used": "muted",
      " (2h)": "dim",
      read: "toolTitle",
      "tasks ": "muted",
      "0/1": "mdLink",
      " Review": "text",
      "agents ": "muted",
      "2": "mdLink",
      "plan: implementation": "accent",
      "⚡⚡": "warning",
      "$0.00": "dim",
      "50m": "dim",
      "  ": "border",
      "": "border",
    });
  });

  it.each([
    { changes: {}, expected: "success" },
    { changes: { staged: 1 }, expected: "warning" },
    { changes: { unstaged: 1 }, expected: "warning" },
    { changes: { untracked: 1 }, expected: "warning" },
    { changes: { conflicts: 1 }, expected: "error" },
    { changes: { stale: true }, expected: "dim" },
    { changes: { staged: 1, stale: true }, expected: "dim" },
  ])(
    "colours full and compact Git branches for $changes",
    ({ changes, expected }) => {
      const state = fixture();

      state.git = { ...parseGitStatus("# branch.head main", now), ...changes };

      const fg = vi.fn((_role: ThemeColor, value: string) => value);

      renderFooter(state, 400, { fg, bold: (value) => value });

      expect(
        fg.mock.calls.filter(([, value]) => value === "main"),
      ).toStrictEqual([
        [expected, "main"],
        [expected, "main"],
      ]);
    },
  );

  it.each([
    ["off", "thinkingOff"],
    ["minimal", "thinkingMinimal"],
    ["low", "thinkingLow"],
    ["medium", "thinkingMedium"],
    ["high", "thinkingHigh"],
    ["xhigh", "thinkingXhigh"],
    ["max", "thinkingMax"],
    ["unknown", "muted"],
  ])("uses the theme's thinking colour for %s", (level, expected) => {
    const state = fixture();

    state.thinking = level;

    expect(colours(state).get(level)).toBe(expected);
  });

  it.each([
    [null, "?", "dim"],
    [24.3, "24.3%", "toolTitle"],
    [75, "75.0%", "warning"],
    [90, "90.0%", "error"],
  ])(
    "colours context value %s without highlighting its capacity",
    (percent, value, expected) => {
      const state = fixture();

      state.context.percent = percent;

      const roles = colours(state);

      expect({
        value: roles.get(String(value)),
        capacity: roles.get("/272k"),
      }).toStrictEqual({ value: expected, capacity: "dim" });
    },
  );

  it.each([
    { age: 0, error: undefined, value: "toolTitle", freshness: undefined },
    { age: 1000, error: "LIMIT", value: "warning", freshness: " cached" },
    { age: 31_000, error: undefined, value: "warning", freshness: " stale" },
    { age: 300_001, error: undefined, value: undefined, freshness: undefined },
  ])(
    "keeps freshness explicit at age $age with error $error",
    ({ age, error, value, freshness }) => {
      const roles = colours(fixture(age, error));

      expect({
        label: roles.get("5h"),
        value: roles.get("15%"),
        freshness: freshness ? roles.get(freshness) : undefined,
        unavailable: roles.get("unavailable"),
      }).toStrictEqual({
        label: "muted",
        value,
        freshness: freshness ? "warning" : undefined,
        unavailable: value ? undefined : "dim",
      });
    },
  );

  it("distinguishes errors from warnings and colours compact attention variants", () => {
    const state = fixture();

    state.activity.outcome = "failed";
    state.statuses = new Map([["pi-lens-lsp", "language server ✗"]]);
    state.diagnostics.receive({
      v: 1,
      cwd: state.cwd,
      seq: 1,
      files: [
        {
          path: "fixture.ts",
          diagnostics: [
            { severity: "error", message: "Synthetic error" },
            { severity: "warning", message: "Synthetic warning" },
          ],
        },
      ],
    });

    const roles = colours(state);

    expect(
      Object.fromEntries(
        ["run failed", "1E", "1W", "LSP failed"].map((value) => [
          value,
          roles.get(value),
        ]),
      ),
    ).toStrictEqual({
      "run failed": "error",
      "1E": "error",
      "1W": "warning",
      "LSP failed": "error",
    });
  });
});
