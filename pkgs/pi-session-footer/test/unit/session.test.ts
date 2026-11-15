import { expect, it } from "vitest";
import {
  FooterSession,
  type FooterContext,
} from "#footer/application/session.ts";
import { gitState } from "#test/support/git.ts";
import { renderFooter } from "#test/support/layout.ts";
import { quotaWindows, readQuota } from "#footer/domain/quota.ts";
import { readAgents } from "#footer/domain/workflow.ts";
import { record } from "#footer/shared/text.ts";

import { dependencies } from "#test/support/dependencies.ts";

const view = { shown: () => "", redraw: () => {} };

function harness() {
  const handlers = new Map<string, Set<(value: unknown) => void>>();
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
    emit: (key: string, value: unknown) => {
      for (const handler of handlers.get(key) ?? []) {
        handler(value);
      }
    },
  };
  const context: FooterContext = {
    cwd: "/work",
    model: { id: "fixture", provider: "openai", contextWindow: 200_000 },
    thinkingLevel: "high",
    getContextUsage: (): undefined => {},
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

/**
 * Starts a session whose change notifications redraw `screen.lines`, as the
 * controller redraws the footer.
 */
function display(h: ReturnType<typeof harness>) {
  const screen = { lines: [] as string[] };
  const session: FooterSession = new FooterSession(
    h.context,
    h.bus,
    () => {
      screen.lines = renderFooter(session.state, 200);
    },
    h.runtime,
    view,
  );
  screen.lines = renderFooter(session.state, 200);
  const shows = (text: string) => screen.lines.join("\n").includes(text);
  return { session, screen, shows };
}

it("disposes timers, replies and late Git reads without changing a replaced session", async () => {
  const h = harness();
  h.runtime.repository.state = gitState("main", 0);
  const release = h.runtime.repository.hold();
  const { session, screen } = display(h);
  const initial = screen.lines;

  session.dispose();
  release();
  await h.runtime.clock.advance(0);

  expect({
    listeners: h.handlers.size,
    timers: h.runtime.clock.pending,
    git: session.state.git,
    lines: screen.lines,
  }).toStrictEqual({
    listeners: 0,
    timers: 0,
    git: undefined,
    lines: initial,
  });
});

it("preserves an initial PR reading for the current branch", async () => {
  const { bus, context, runtime } = harness();
  runtime.repository.state = gitState("main", 1);
  const release = runtime.repository.hold();
  const session = new FooterSession(context, bus, () => {}, runtime, view);
  const pr = {
    protocol: 1 as const,
    source: "pi-prs" as const,
    repository: "a/b",
    branch: "main",
    health: "ok" as const,
    updatedAt: 1,
  };

  session.receivePr(pr);

  release();
  await runtime.clock.advance(0);

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
      view,
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

it("shows the session age from the header timestamp at the minute boundary", async () => {
  const now = Date.UTC(2026, 9, 20, 12, 0, 30);
  const h = harness();
  h.runtime.clock.set(now);
  h.context.sessionManager.getHeader = () => ({
    timestamp: new Date(now).toISOString(),
  });
  const { session, shows } = display(h);

  await h.runtime.clock.advance(59_000);
  const before = shows(" 1m");
  await h.runtime.clock.advance(1000);

  expect({ before, after: shows(" 1m") }).toStrictEqual({
    before: false,
    after: true,
  });

  session.dispose();
});

it.each<{ field: string; change: (context: FooterContext) => void }>([
  { field: "nothing", change: () => {} },
  {
    field: "model",
    change: (context) => {
      context.model = {
        id: "replacement",
        provider: "openai",
        contextWindow: 200_000,
      };
    },
  },
  {
    field: "thinking",
    change: (context) => {
      context.thinkingLevel = "low";
    },
  },
  {
    field: "context",
    change: (context) => {
      context.getContextUsage = () => ({
        tokens: 1000,
        contextWindow: 200_000,
        percent: 0.5,
      });
    },
  },
  {
    field: "pending",
    change: (context) => {
      context.hasPendingMessages = () => true;
    },
  },
])(
  "redraws when a tick changes the displayed $field",
  async ({ field, change }) => {
    const h = harness();
    h.context.model = {
      id: "fixture",
      provider: "openai",
      contextWindow: 200_000,
      reasoning: true,
    };
    const { session, screen } = display(h);

    await h.runtime.clock.advance(0);
    const initial = screen.lines;
    change(h.context);
    await h.runtime.clock.advance(1000);

    expect({
      lines: screen.lines,
      changed: JSON.stringify(screen.lines) !== JSON.stringify(initial),
    }).toStrictEqual({
      lines: renderFooter(session.state, 200),
      changed: field !== "nothing",
    });

    session.dispose();
  },
);

it("reads Git again when a refresh is requested during a pending read", async () => {
  const h = harness();
  h.runtime.repository.state = gitState("main", 0);
  const release = h.runtime.repository.hold();
  const { session, shows } = display(h);

  h.runtime.repository.state = gitState("feature", 0);
  const requested = session.refreshGit();
  release();
  await requested;
  await h.runtime.clock.advance(0);

  expect({
    git: session.state.git,
    shown: shows("feature"),
  }).toStrictEqual({
    git: gitState("feature", h.runtime.clock.now()),
    shown: true,
  });

  session.dispose();
});

it("polls Git a fixed interval after the previous read finishes", async () => {
  const h = harness();
  h.runtime.repository.state = gitState("main", 0);
  h.runtime.repository.duration = 3000;
  const { session, shows } = display(h);

  await h.runtime.clock.advance(4000);
  h.runtime.repository.state = gitState("feature", 0);
  await h.runtime.clock.advance(6000);
  const tenSeconds = shows("feature");
  await h.runtime.clock.advance(1000);

  expect({ tenSeconds, elevenSeconds: shows("feature") }).toStrictEqual({
    tenSeconds: false,
    elevenSeconds: true,
  });

  session.dispose();
});

it("backs off Git polling after failures and resets after a success", async () => {
  const h = harness();
  const start = h.runtime.clock.now();
  h.runtime.repository.failure = new Error("Git timed out");
  const { session, shows } = display(h);
  await h.runtime.clock.advance(0);
  const at = (seconds: number) =>
    h.runtime.clock.advance(start + seconds * 1000 - h.runtime.clock.now());

  await at(100);
  h.runtime.repository.failure = undefined;
  h.runtime.repository.state = gitState("main", 0);
  await at(129);
  const beforeRetry = shows(" main");
  await at(130);
  const afterRetry = shows(" main");
  await at(131);
  h.runtime.repository.state = gitState("feature", 0);
  await at(134);
  const beforePoll = shows("feature");
  await at(135);

  expect({
    beforeRetry,
    afterRetry,
    beforePoll,
    afterPoll: shows("feature"),
  }).toStrictEqual({
    beforeRetry: false,
    afterRetry: true,
    beforePoll: false,
    afterPoll: true,
  });

  session.dispose();
});

it("shows an inactivity warning after 30 s without content and clears it on content", async () => {
  const h = harness();
  const { session, shows } = display(h);

  await h.runtime.clock.advance(2500);
  session.activity("start");
  await h.runtime.clock.advance(31_000);
  const warned = shows("no content 0m");
  session.activity("content");

  expect({ warned, cleared: !shows("no content") }).toStrictEqual({
    warned: true,
    cleared: true,
  });

  session.dispose();
});

it("preserves bounded Git errors through failure and recovery without calling non-repositories errors", async () => {
  const { bus, context, runtime } = harness();
  runtime.repository.failure = new Error("Permission denied\nfor fixture");
  const session = new FooterSession(context, bus, () => {}, runtime, view);

  await runtime.clock.advance(0);

  expect({
    git: session.state.git,
    error: session.state.gitError,
  }).toStrictEqual({
    git: undefined,
    error: "Permission denied for fixture",
  });

  runtime.repository.failure = undefined;
  runtime.repository.state = gitState("main", 0);
  await session.refreshGit();
  const fresh = gitState("main", runtime.clock.now());

  expect({
    git: session.state.git,
    error: session.state.gitError,
  }).toStrictEqual({
    git: fresh,
    error: undefined,
  });

  runtime.repository.failure = new Error("Git unavailable");
  await session.refreshGit();

  expect({
    git: session.state.git,
    error: session.state.gitError,
  }).toStrictEqual({
    git: { ...fresh, stale: true },
    error: "Git unavailable",
  });

  runtime.repository.failure = undefined;
  runtime.repository.state = undefined;
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
  const session = new FooterSession(context, bus, () => {}, runtime, view);

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
  const session = new FooterSession(context, bus, () => {}, runtime, view);

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
