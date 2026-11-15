import { expect, it } from "vitest";
import { record } from "#footer/shared/text.ts";
import { UsageLedger } from "#footer/domain/usage.ts";
import { RpcClient } from "#footer/integrations/rpc.ts";
import { readPr, readServiceTier } from "#footer/integrations/integrations.ts";
import { detailsLines } from "#footer/ui/inspection/inspector.ts";
import { createSnapshot } from "#footer/domain/state.ts";

import { dependencies } from "#test/support/dependencies.ts";

it("counts whole-session records once and takes cache hit rate from the active branch", () => {
  const ledger = new UsageLedger();
  const entries = [
    {
      id: "a",
      type: "message",
      message: {
        role: "assistant",
        usage: {
          input: 10,
          output: 20,
          cacheRead: 90,
          cacheWrite: 0,
          cost: { total: 1 },
        },
      },
    },
    {
      id: "b",
      type: "message",
      message: {
        role: "toolResult",
        usage: { input: 2, output: 3, cost: { total: 0.1 } },
        details: { nestedCalls: [{ usage: { cost: { total: 99 } } }] },
      },
    },
    {
      id: "c",
      type: "compaction",
      usage: { input: 3, output: 2, cost: { total: 0.2 } },
    },
    {
      id: "d",
      type: "usage",
      usage: { input: 1, output: 1, cost: { total: 0.3 } },
    },
  ];

  ledger.update(entries, entries.slice(0, 1));

  expect(ledger.latestPrompt).toStrictEqual({ cached: 90, total: 100 });
  expect(ledger.totals).toStrictEqual({
    input: 16,
    output: 26,
    cacheRead: 90,
    cacheWrite: 0,
    cost: 1.6,
    costFromProvider: false,
    latestHit: 90,
  });

  ledger.update(entries, []);

  expect(ledger.totals).toStrictEqual({
    input: 16,
    output: 26,
    cacheRead: 90,
    cacheWrite: 0,
    cost: 1.6,
    costFromProvider: false,
    latestHit: undefined,
  });

  ledger.update([], []);

  expect(ledger.totals).toStrictEqual({
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cost: 0,
    costFromProvider: false,
    latestHit: undefined,
  });
});

it.each([
  { billed: [true, true], costFromProvider: true },
  { billed: [true, false], costFromProvider: false },
  { billed: [true, undefined], costFromProvider: false },
  { billed: [false, false], costFromProvider: false },
  { billed: [], costFromProvider: false },
])(
  "marks the session cost provider-reported only when every part is: $billed",
  ({ billed, costFromProvider }) => {
    const ledger = new UsageLedger();
    const entries = billed.map((fromProvider, index) => ({
      id: String(index),
      type: "usage",
      usage: {
        input: 1,
        output: 1,
        ...(fromProvider === undefined
          ? {}
          : {
              cost: fromProvider
                ? { total: 0.5, totalFromProvider: true }
                : { total: 0.5 },
            }),
      },
    }));

    ledger.update(entries, []);

    expect(ledger.totals).toStrictEqual({
      input: billed.length,
      output: billed.length,
      cacheRead: 0,
      cacheWrite: 0,
      cost: 0.5 * billed.filter((value) => value !== undefined).length,
      costFromProvider,
      latestHit: undefined,
    });
  },
);

it.each([
  {
    costFromProvider: false,
    lines: [
      "Whole-session recorded estimate: $1.5000 (includes abandoned branches, reported tool usage, summaries and cache warming; not a verified invoice)",
      "Auxiliary recorded estimate (separate from session cost): $0.2500",
    ],
  },
  {
    costFromProvider: true,
    lines: [
      "Whole-session billed total reported by the provider: $1.5000 (includes abandoned branches, reported tool usage, summaries and cache warming)",
      "Auxiliary billed total reported by the provider (separate from session cost): $0.2500",
    ],
  },
])(
  "describes cost totals by their source when provider-reported is $costFromProvider",
  ({ costFromProvider, lines }) => {
    const state = createSnapshot(100, "/work");
    state.usage = { ...state.usage, cost: 1.5, costFromProvider };
    state.auxiliaryUsage = {
      ...state.auxiliaryUsage,
      cost: 0.25,
      costFromProvider,
    };

    expect(detailsLines(state, "usage").slice(0, 2)).toStrictEqual(lines);
  },
);

it("correlates RPC replies and cleans up timeout and disposal", async () => {
  const handlers = new Map<string, (value: unknown) => void>();
  let request: Record<string, unknown> = {};
  const bus = {
    on: (key: string, handler: (value: unknown) => void) => {
      handlers.set(key, handler);

      return () => {
        handlers.delete(key);
      };
    },
    emit: (_key: string, value: unknown) => {
      if (record(value)) {
        request = { ...value };
      }
    },
  };
  const runtime = dependencies();
  const client = new RpcClient(bus, runtime);
  const result = client.request("status");
  if (typeof request.requestId !== "string") {
    throw new TypeError("Expected an RPC request ID");
  }

  const reply = handlers.get(`subagents:rpc:v1:reply:${request.requestId}`);

  reply?.({ version: 1, requestId: "other", success: true, data: "wrong" });
  reply?.({
    version: 1,
    requestId: request.requestId,
    success: true,
    data: { active: 2 },
  });

  expect(await result).toStrictEqual({ ok: true, data: { active: 2 } });

  const missing = client.request("status");

  await runtime.clock.advance(2000);

  expect(await missing).toStrictEqual({
    ok: false,
    error: { kind: "timeout", message: "RPC status timed out" },
  });

  const disposed = client.request("cost");

  client.dispose();

  expect(await disposed).toStrictEqual({
    ok: false,
    error: { kind: "disposed", message: "RPC client disposed" },
  });
  expect(handlers.size).toBe(0);
  expect(runtime.clock.pending).toBe(0);
});

it("only accepts passive PR state and safe service-tier snapshots", () => {
  expect(
    readPr({
      protocol: 1,
      source: "pi-prs",
      repository: "a/b",
      branch: "main",
      health: "unauthenticated",
      updatedAt: 10,
    }),
  ).toStrictEqual({
    protocol: 1,
    source: "pi-prs",
    repository: "a/b",
    branch: "main",
    health: "unauthenticated",
    updatedAt: 10,
    pullRequest: undefined,
  });
  expect(
    readPr({
      protocol: 1,
      source: "pi-prs",
      pullRequest: { target: { number: -1 } },
    }),
  ).toBeUndefined();
  expect(
    readServiceTier({
      protocol: 1,
      type: "upsert",
      widget: {
        id: "pi-service-tier.service-tier",
        content: { text: "⚡ fast" },
      },
    }),
  ).toBe("⚡ fast");
  expect(
    readServiceTier({
      protocol: 1,
      type: "remove",
      id: "pi-service-tier.service-tier",
    }),
  ).toBe("");
});

it.each(["reviews", "checks"])(
  "does not interpret missing %s counts as zero",
  (missing) => {
    expect(
      readPr({
        protocol: 1,
        source: "pi-prs",
        repository: "a/b",
        branch: "main",
        health: "ok",
        updatedAt: 10,
        pullRequest: {
          target: { number: 1 },
          lifecycle: "open",
          mergeState: "unknown",
          unresolvedThreadCount: missing === "reviews" ? undefined : 0,
          ci: {
            state: "failed",
            failedCount: missing === "checks" ? undefined : 0,
          },
        },
      }),
    ).toBeUndefined();
  },
);

it("does not insert a blank PR detail line without a CI URL", () => {
  const state = createSnapshot(100, "/work");

  state.pr = readPr({
    protocol: 1,
    source: "pi-prs",
    repository: "a/b",
    branch: "main",
    health: "ok",
    updatedAt: 10,
    pullRequest: {
      target: { number: 1, url: "https://github.com/a/b/pull/1" },
      lifecycle: "open",
      mergeState: "unknown",
      unresolvedThreadCount: 0,
    },
  });

  expect(detailsLines(state, "git").slice(-6)).toStrictEqual([
    "PR #1: https://github.com/a/b/pull/1",
    "Merge: unknown · open",
    "Review threads: 0 unresolved",
    "CI: unknown · ? failures",
    "Watching: off",
    "PR integration is passive by default. Missing authentication and unsuccessful reads are not successful checks.",
  ]);
});

it("labels missing measurements and accounting scope in the inspector", () => {
  const state = createSnapshot(100, "/work");

  const details = {
    quota: detailsLines(state, "quota"),
    diagnostics: detailsLines(state, "diagnostics"),
    usage: detailsLines(state, "usage"),
  };
  expect(details).toStrictEqual({
    quota: [
      "Quota percentages are used, not remaining.",
      "Provider: unavailable",
      "Account identity: unavailable (account of the reading; runtime identity is not verified)",
      "Credential source: unavailable",
      "Last successful fetch: unavailable",
      "Last error: none reported",
      "Pace compares quota consumed with the elapsed fraction of a reported-duration window. It is a heuristic, not a forecast.",
      "Cached readings become stale after 30 seconds; percentages expire after five minutes or the quota reset.",
    ],
    diagnostics: [
      "Coverage: unknown",
      "Received findings: 0 errors, 0 warnings, 0 files pending",
      "Missing diagnostics or MCP inventory does not establish clean files or healthy servers.",
      "Use /lens-widget-toggle to show pi-lens's native diagnostic widget.",
    ],
    usage: [
      "Whole-session recorded estimate: $0.0000 (includes abandoned branches, reported tool usage, summaries and cache warming; not a verified invoice)",
      "Auxiliary recorded estimate (separate from session cost): $0.0000",
      "Auxiliary tokens: input 0, output 0, cache read 0, cache write 0",
      "Tokens: input 0, output 0, cache read 0, cache write 0",
      "Latest active-branch request cache hit rate: unknown",
      "Whole-session cache hit rate: unknown",
      "Live session age: 0m",
      "Current run duration: not running",
      "Observed active-work time: 0m (observed since 1970-01-01T00:00:00.100Z)",
      "Current tool: none",
      "Compaction duration: not compacting",
      "Cache hit rate is not an estimate of invoice savings.",
      "Delegation last error: none reported",
      "Delegation report (separate scope; not added to session cost; safe raw JSON, capped at 2000 columns and 4096 source characters; ellipsis indicates truncation):",
      "unavailable",
    ],
  });
});

it.each(["threads", "checks"])("rejects fractional PR %s counts", (field) => {
  expect(
    readPr({
      protocol: 1,
      source: "pi-prs",
      repository: "a/b",
      branch: "main",
      health: "ok",
      updatedAt: 10,
      pullRequest: {
        target: { number: 1 },
        lifecycle: "open",
        mergeState: "unknown",
        unresolvedThreadCount: field === "threads" ? 0.5 : 0,
        ci: { state: "okay", failedCount: field === "checks" ? 0.5 : 0 },
      },
    }),
  ).toBeUndefined();
});

it.each([8.64e15, 8.64e15 + 1])(
  "accepts PR timestamps only within the date range: %d",
  (updatedAt) => {
    const event = {
      protocol: 1,
      source: "pi-prs",
      repository: "a/b",
      branch: "main",
      health: "ok",
      updatedAt,
    } as const;

    expect(readPr(event)).toStrictEqual(
      updatedAt === 8.64e15 ? { ...event, pullRequest: undefined } : undefined,
    );
  },
);

it.each([
  { label: "a BigInt", report: { total: 1n } },
  {
    label: "a circular object",
    report: (() => {
      const report: Record<string, unknown> = {};
      report.self = report;
      return report;
    })(),
  },
])("describes $label delegation report it cannot serialise", ({ report }) => {
  const state = createSnapshot(100, "/work");
  state.delegationCost = report;

  expect(detailsLines(state, "usage").at(-1)).toBe(
    "unavailable: the report cannot be serialised as JSON",
  );
});
