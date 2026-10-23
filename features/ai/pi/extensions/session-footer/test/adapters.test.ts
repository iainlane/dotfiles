import { afterEach, expect, it, vi } from "vitest";
import { UsageLedger } from "../src/usage.ts";
import { RpcClient } from "../src/rpc.ts";
import { readPr, readServiceTier } from "../src/integrations.ts";
import { detailsLines } from "../src/inspector.ts";
import { createSnapshot } from "../src/state.ts";

afterEach(() => vi.useRealTimers());

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

  expect(ledger.totals).toStrictEqual({
    input: 16,
    output: 26,
    cacheRead: 90,
    cacheWrite: 0,
    cost: 1.6,
    latestHit: 90,
  });

  ledger.update(entries, []);

  expect(ledger.totals).toStrictEqual({
    input: 16,
    output: 26,
    cacheRead: 90,
    cacheWrite: 0,
    cost: 1.6,
    latestHit: undefined,
  });

  ledger.update([], []);

  expect(ledger.totals).toStrictEqual({
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cost: 0,
    latestHit: undefined,
  });
});

it("correlates RPC replies and cleans up timeout and disposal", async () => {
  vi.useFakeTimers();

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
      if (value && typeof value === "object") request = { ...value };
    },
  };
  const client = new RpcClient(bus);
  const result = client.request("status");
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

  await vi.advanceTimersByTimeAsync(2000);

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
  expect(vi.getTimerCount()).toBe(0);
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

  expect(detailsLines(state, "quota").join("\n")).toContain(
    "Account identity: unavailable",
  );
  expect(detailsLines(state, "diagnostics").join("\n")).toContain(
    "Coverage: unknown",
  );
  expect(detailsLines(state, "usage").join("\n")).toContain(
    "Whole-session recorded estimate",
  );
});
