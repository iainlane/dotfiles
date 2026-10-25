import { expect, it, vi } from "vitest";
import { FooterSession, type FooterContext } from "../src/session.ts";
import { parseGitStatus } from "../src/git.ts";
import { quotaWindows, readQuota } from "../src/quota.ts";
import { readAgents } from "../src/workflow.ts";
import { record } from "../src/text.ts";

import { dependencies } from "./dependencies.ts";

function harness() {
  const handlers = new Map<string, Set<(value: unknown) => void>>();
  const emit = vi.fn<(key: string, value: unknown) => void>(
    (key: string, value: unknown) => {
      for (const handler of handlers.get(key) ?? []) {
        handler(value);
      }
    },
  );
  const bus = {
    on: (key: string, handler: (value: unknown) => void) => {
      const set = handlers.get(key) ?? new Set();

      set.add(handler);
      handlers.set(key, set);

      return () => {
        set.delete(handler);

        if (set.size === 0) {
          handlers.delete(key);
        }
      };
    },
    emit,
  };
  const context: FooterContext = {
    cwd: "/work",
    model: { id: "fixture", provider: "openai-codex", contextWindow: 200_000 },
    thinkingLevel: "high",
    getContextUsage: () => {},
    hasPendingMessages: () => false,
    sessionManager: {
      getHeader: () => ({ timestamp: "2026-10-20T12:00:00Z" }),
      getBranch: () => [],
      getEntries: () => [],
      getLeafId: () => null,
    },
  };

  return { bus, context, handlers, runtime: dependencies() };
}

it("disposes timers, replies and late Git requests without changing a replaced session", async () => {
  const { bus, context, handlers, runtime } = harness();
  const change = vi.fn<() => void>();
  const pending = Promise.withResolvers<undefined>();
  const session = new FooterSession(context, bus, change, {
    ...runtime,
    readGit: () => pending.promise,
  });

  session.dispose();
  pending.resolve(undefined);
  await runtime.clock.advance(0);

  expect(handlers.size).toBe(0);
  expect(runtime.clock.pending).toBe(0);
  expect(change).not.toHaveBeenCalled();
});

it("preserves an initial PR reading for the current branch", async () => {
  const { bus, context, runtime } = harness();
  const git = Promise.withResolvers<ReturnType<typeof parseGitStatus>>();
  const session = new FooterSession(context, bus, () => {}, {
    ...runtime,
    readGit: () => git.promise,
  });
  const pr = {
    protocol: 1 as const,
    source: "pi-prs" as const,
    repository: "a/b",
    branch: "main",
    health: "ok" as const,
    updatedAt: 1,
  };

  session.state.pr = pr;

  git.resolve(parseGitStatus("# branch.head main", 1));
  await Promise.resolve();

  expect(session.state.pr).toStrictEqual(pr);

  session.dispose();
});

it.each([
  { label: "staleness", elapsed: 31_000, reset: 600_000, freshness: "stale" },
  {
    label: "expiry",
    elapsed: 301_000,
    reset: 600_000,
    freshness: "unavailable",
  },
  { label: "reset", elapsed: 15_000, reset: 15_000, freshness: "unavailable" },
  { label: "countdown", elapsed: 16_000, reset: 75_000, freshness: "fresh" },
])(
  "invalidates idle quota $label without incoming events or Git data",
  async ({ elapsed, reset, freshness }) => {
    const now = Date.UTC(2026, 9, 20, 12);

    const { bus, context, runtime } = harness();
    runtime.clock.set(now);
    const frames: { at: number; freshness: string[] }[] = [];
    const session = new FooterSession(
      context,
      bus,
      () => {
        frames.push({
          at: runtime.clock.now(),
          freshness: quotaWindows(session.state.quota, session.state.now).map(
            (window) => window.freshness,
          ),
        });
      },
      runtime,
    );

    session.state.quota = readQuota({
      state: {
        provider: "codex",
        usage: {
          lastSuccessAt: now,
          windows: [
            {
              label: "5h",
              usedPercent: 15,
              resetAt: new Date(now + reset).toISOString(),
            },
          ],
        },
      },
    });

    await runtime.clock.advance(elapsed);

    expect(frames.at(-1)).toStrictEqual({
      at: now + elapsed,
      freshness: [freshness],
    });

    session.dispose();
  },
);

it("invalidates session age relative to the header timestamp", async () => {
  const now = Date.UTC(2026, 9, 20, 12, 0, 30);

  const { bus, context, runtime } = harness();
  runtime.clock.set(now);
  const change = vi.fn<() => void>();

  context.sessionManager.getHeader = () => ({
    timestamp: new Date(now).toISOString(),
  });

  const session = new FooterSession(context, bus, change, runtime);

  await runtime.clock.advance(2500);
  change.mockClear();
  await runtime.clock.advance(57_500);

  expect(change.mock.calls).toStrictEqual([[]]);

  session.dispose();
});

it("does not invalidate for routine content but clears a displayed inactivity warning", async () => {
  const { bus, context, runtime } = harness();
  const change = vi.fn<() => void>();
  const session = new FooterSession(context, bus, change, runtime);

  await runtime.clock.advance(2500);

  session.activity("start");
  change.mockClear();
  session.activity("content");
  session.activity("content");

  expect(change.mock.calls).toStrictEqual([]);

  await runtime.clock.advance(31_000);
  change.mockClear();
  session.activity("content");

  expect(change.mock.calls).toStrictEqual([[]]);

  session.dispose();
});

it("preserves bounded Git errors through failure and recovery without calling non-repositories errors", async () => {
  const { bus, context, runtime } = harness();
  const fresh = parseGitStatus("# branch.head main", 100);
  const getGit = vi
    .fn<() => Promise<typeof fresh | undefined>>()
    .mockRejectedValueOnce(new Error("Permission denied\nfor fixture"));
  const session = new FooterSession(context, bus, () => {}, {
    ...runtime,
    readGit: getGit,
  });

  await runtime.clock.advance(0);

  expect({
    git: session.state.git,
    error: session.state.gitError,
  }).toStrictEqual({
    git: undefined,
    error: "Permission denied for fixture",
  });

  getGit.mockResolvedValue(fresh);
  await session.refreshGit();

  expect({
    git: session.state.git,
    error: session.state.gitError,
  }).toStrictEqual({
    git: fresh,
    error: undefined,
  });

  getGit.mockRejectedValue(new Error("Git unavailable"));
  await session.refreshGit();

  expect({
    git: session.state.git,
    error: session.state.gitError,
  }).toStrictEqual({
    git: { ...fresh, stale: true },
    error: "Git unavailable",
  });

  getGit.mockResolvedValue(undefined);
  await session.refreshGit();

  expect({
    git: session.state.git,
    error: session.state.gitError,
  }).toStrictEqual({
    git: undefined,
    error: undefined,
  });

  session.dispose();
});

it("keeps stale subagent data with a reason and clears the failure on recovery", async () => {
  const { bus, context, runtime } = harness();
  const session = new FooterSession(context, bus, () => {}, runtime);

  await runtime.clock.advance(2500);

  expect(session.state.rpcErrors).toStrictEqual({
    status: { kind: "timeout", message: "RPC status timed out" },
    cost: undefined,
  });

  const payload = {
    fleet: { version: 1, totalActive: 0, entries: [], omitted: 0 },
    asyncSnapshot: {
      kind: "pi-subagents.async-status-snapshot",
      version: 1,
      omitted: {},
      runs: [],
    },
  };
  let data: unknown = payload;
  const stop = bus.on("subagents:rpc:v1:request", (raw) => {
    if (!record(raw) || typeof raw.requestId !== "string") {
      return;
    }

    bus.emit(`subagents:rpc:v1:reply:${raw.requestId}`, {
      version: 1,
      requestId: raw.requestId,
      success: true,
      data,
    });
  });

  await session.refreshAgents();

  const healthy = readAgents(payload);

  expect({
    agents: session.state.agents,
    error: session.state.rpcErrors.status,
  }).toStrictEqual({
    agents: healthy,
    error: undefined,
  });

  data = "invalid";
  await session.refreshAgents();

  expect({
    agents: session.state.agents,
    error: session.state.rpcErrors.status,
  }).toStrictEqual({
    agents: { ...healthy, stale: true },
    error: { kind: "malformed", message: "Invalid subagent status data" },
  });

  data = payload;
  await session.refreshAgents();

  expect({
    agents: session.state.agents,
    error: session.state.rpcErrors.status,
  }).toStrictEqual({
    agents: healthy,
    error: undefined,
  });

  stop();
  session.dispose();
});

it("does not count time spent waiting for user input as active work", async () => {
  const { bus, context, runtime } = harness();
  const session = new FooterSession(context, bus, () => {}, runtime);

  session.activity("start");
  await runtime.clock.advance(5000);
  session.activity("wait");
  await runtime.clock.advance(30_000);
  session.activity("resume");
  await runtime.clock.advance(5000);
  session.activity("settled");

  expect(session.state.activity.activeMs).toBe(10_000);
  expect(session.state.activity.runningSince).toBeUndefined();

  session.dispose();
});
