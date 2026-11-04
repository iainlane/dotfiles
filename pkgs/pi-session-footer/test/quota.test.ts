import { describe, expect, it } from "vitest";
import { readQuota, quotaWindows } from "../src/quota.ts";

const now = Date.UTC(2026, 9, 20, 12);

const event = (windows: unknown[], extra = {}) => ({
  state: {
    provider: "codex",
    usage: { provider: "codex", windows, lastSuccessAt: now, ...extra },
  },
});

describe("quota readings", () => {
  it.each([
    [0, "fresh", 15, "2h", -45],
    [31_000, "stale", 15, "1h59m", -45],
    [301_000, "unavailable", undefined, undefined, undefined],
    [7_200_000, "unavailable", undefined, undefined, undefined],
  ] as const)(
    "represents a reading after %i milliseconds",
    (elapsed, freshness, used, reset, pace) => {
      const reading = readQuota(
        event([
          {
            label: "5h",
            usedPercent: 15,
            resetAt: new Date(now + 7_200_000).toISOString(),
            windowSeconds: 18_000,
          },
        ]),
      );

      expect(quotaWindows(reading, now + elapsed)).toStrictEqual([
        { label: "5h", used, reset, pace, freshness },
      ]);
    },
  );

  it("does not infer durations or missing windows from labels", () => {
    const reading = readQuota(event([{ label: "Week", usedPercent: 2 }]));

    expect(quotaWindows(reading, now)).toStrictEqual([
      {
        label: "Week",
        used: 2,
        reset: undefined,
        pace: undefined,
        freshness: "fresh",
      },
    ]);
  });

  it("retains a failed refresh as cached without extending its timestamp", () => {
    const previous = readQuota(event([{ label: "Week", usedPercent: 18 }]));
    const failed = readQuota(
      event([], { error: { code: "TIMEOUT" }, lastSuccessAt: undefined }),
      previous,
    );

    expect(failed).toStrictEqual({ ...previous, error: "TIMEOUT" });
    expect(quotaWindows(failed, now)[0]?.freshness).toBe("cached");
  });

  it.each([
    null,
    { state: null },
    { state: { provider: "codex", usage: null } },
    { state: { provider: "codex", usage: { windows: "broken" } } },
  ])(
    "preserves a previous same-provider reading after malformed input %j",
    (raw) => {
      const previous = readQuota(event([{ label: "Week", usedPercent: 18 }]));
      const next = readQuota(raw, previous);

      expect(next).toStrictEqual({ ...previous, error: "INVALID_UPDATE" });
      expect(quotaWindows(next, now + 301_000)).toStrictEqual([
        {
          label: "Week",
          used: undefined,
          reset: undefined,
          pace: undefined,
          freshness: "unavailable",
        },
      ]);
    },
  );

  it.each([
    { state: { provider: undefined, usage: undefined } },
    { state: { provider: "codex", usage: undefined } },
    { state: { provider: "anthropic", usage: null } },
  ])(
    "does not retain old data after an explicit clear or provider change %j",
    (raw) => {
      expect(
        readQuota(raw, readQuota(event([{ label: "Week", usedPercent: 18 }]))),
      ).toBeUndefined();
    },
  );

  it("clears old provider readings and rejects invalid percentages", () => {
    expect(
      readQuota({ state: { provider: "anthropic" } }, readQuota(event([]))),
    ).toBeUndefined();
    expect(
      quotaWindows(readQuota(event([{ label: "bad", usedPercent: NaN }])), now),
    ).toStrictEqual([
      {
        label: "bad",
        used: undefined,
        reset: undefined,
        pace: undefined,
        freshness: "unavailable",
      },
    ]);
  });
});
