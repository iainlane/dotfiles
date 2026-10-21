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
      state.statuses = new Map([["other", "extra \u001b[31mstatus"]]);

      const lines = renderFooter(state, width);

      expect(lines.length).toBeLessThanOrEqual(2);
      expect(lines.every((line) => visibleWidth(line) <= width)).toBe(true);
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
