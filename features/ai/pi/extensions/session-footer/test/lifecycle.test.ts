import { isReply } from "./requests.ts";
import { expect, it, vi } from "vitest";
import {
  createFooter,
  type FooterUIContext,
  type FooterView,
} from "../src/controller.ts";
import { dependencies } from "./dependencies.ts";
import { record } from "../src/text.ts";

function harness(mode = "tui") {
  const channels = new Map<string, Set<(value: unknown) => void>>();
  const emitted: string[] = [];
  const events = {
    on(channel: string, callback: (value: unknown) => void) {
      const listeners = channels.get(channel) ?? new Set();

      listeners.add(callback);
      channels.set(channel, listeners);

      return () => {
        listeners.delete(callback);

        if (listeners.size === 0) {
          channels.delete(channel);
        }
      };
    },
    emit(channel: string, raw: unknown) {
      emitted.push(channel);

      for (const callback of channels.get(channel) ?? []) {
        callback(raw);
      }

      if (channel === "sub-core:request" && record(raw) && isReply(raw.reply)) {
        raw.reply({
          state: {
            provider: "codex",
            usage: {
              lastSuccessAt: runtime.clock.now(),
              windows: [{ label: "Week", usedPercent: 2 }],
            },
          },
        });
      }

      if (
        channel === "subagents:rpc:v1:request" &&
        record(raw) &&
        typeof raw.requestId === "string"
      ) {
        events.emit(`subagents:rpc:v1:reply:${raw.requestId}`, {
          version: 1,
          requestId: raw.requestId,
          success: true,
          data: {
            fleet: { version: 1, totalActive: 0, entries: [], omitted: 0 },
            asyncSnapshot: {
              kind: "pi-subagents.async-status-snapshot",
              version: 1,
              omitted: {},
              runs: [],
            },
          },
        });
      }
    },
  };
  const runtime = dependencies();
  const setFooter = vi.fn<FooterUIContext["ui"]["setFooter"]>();
  const context: FooterUIContext = {
    mode,
    cwd: "/footer-fixture",
    model: { id: "fixture", provider: "openai-codex", contextWindow: 200_000 },
    thinkingLevel: "high",
    getContextUsage: () => {},
    hasPendingMessages: () => false,
    sessionManager: {
      getHeader: () => ({ timestamp: "2026-10-20T12:00:00Z" }),
      getEntries: () => [],
      getBranch: () => [],
      getLeafId: () => null,
    },
    ui: {
      theme: { fg: (_role, value) => value, bold: (value) => value },
      select: async () => {},
      notify: vi.fn<FooterUIContext["ui"]["notify"]>(),
      custom: async () => {},
      setFooter,
    },
  };
  const footer = createFooter({
    events,
    runtime,
    subscribePr: (callback) => events.on("pr:state", callback),
  });
  const emit = (
    event: { type: "session_start" | "session_shutdown"; reason: string },
    current = context,
  ) => {
    if (event.type === "session_start") {
      footer.start(current);
      return;
    }
    footer.shutdown();
  };
  return {
    context,
    emit,
    channels,
    emitted,
    setFooter,
    events,
    footer,
    runtime,
  };
}

it.each(["sub-core:ready", "sub-core:update-current"])(
  "keeps fresh quota updates between clock ticks available on %s",
  async (channel) => {
    const h = harness();

    h.emit({ type: "session_start", reason: "startup" }, h.context);

    const factory = h.setFooter.mock.lastCall?.[0];

    if (!factory) {
      throw new Error("Expected the session footer factory");
    }

    const tui = { requestRender: vi.fn<() => void>() };

    const view = factory(tui, h.context.ui.theme, {
      getExtensionStatuses: () => new Map(),
      onBranchChange: () => () => {},
    });
    const readings: string[] = [];

    for (const delay of [250, 1000, 5000]) {
      // eslint-disable-next-line no-await-in-loop -- Each update must observe the clock advanced by the previous iteration.
      await h.runtime.clock.advance(delay);
      h.events.emit(channel, {
        state: {
          provider: "codex",
          usage: {
            lastSuccessAt: h.runtime.clock.now(),
            windows: [{ label: "Week", usedPercent: 42 }],
          },
        },
      });
      readings.push(view.render(120)[1]?.trim() ?? "");
    }

    expect(readings).toStrictEqual(
      Array.from({ length: 3 }, () => " week 42% used  $0.00  0m"),
    );

    h.emit({ type: "session_shutdown", reason: "quit" }, h.context);
  },
);

it("renders a failed message_end before settlement and cancellation", async () => {
  const h = harness();

  h.emit({ type: "session_start", reason: "startup" }, h.context);

  const factory = h.setFooter.mock.lastCall?.[0];

  if (!factory) {
    throw new Error("Expected the session footer factory");
  }

  let view: FooterView | undefined;
  const frames: string[][] = [];
  const tui = {
    requestRender() {
      if (view) {
        frames.push(view.render(200));
      }
    },
  };

  view = factory(tui, h.context.ui.theme, {
    getExtensionStatuses: () => new Map(),
    onBranchChange: () => () => {},
  });
  frames.length = 0;

  h.footer.endMessage(h.context, true);
  const failed = frames.at(-1)?.join("\n") ?? "";

  h.footer.settleAgent(h.context, false);
  const settled = frames.at(-1)?.join("\n") ?? "";

  h.footer.endMessage(h.context, true);
  h.footer.settleAgent(h.context, true);
  const cancelled = frames.at(-1)?.join("\n") ?? "";

  expect({
    failed: failed.includes("run failed"),
    settled: settled.includes("run failed"),
    cancelled: cancelled.includes("run cancelled"),
  }).toStrictEqual({
    failed: true,
    settled: true,
    cancelled: true,
  });

  h.emit({ type: "session_shutdown", reason: "quit" }, h.context);
});

it("reconnects sources after session replacement and never enables PR automation", async () => {
  const h = harness();

  h.emit({ type: "session_start", reason: "startup" }, h.context);
  await Promise.resolve();

  const connected = h.channels.size;

  expect(h.setFooter).toHaveBeenCalledTimes(1);

  h.emit({ type: "session_shutdown", reason: "new" }, h.context);

  expect(h.channels.size).toBe(0);
  expect(h.runtime.clock.pending).toBe(0);

  h.emit({ type: "session_start", reason: "new" }, h.context);
  await Promise.resolve();

  expect(h.channels.size).toBe(connected);
  expect(h.setFooter).toHaveBeenCalledTimes(2);
  expect(
    h.emitted.filter((channel) =>
      /feedback|ci-failure|sub-core:action/.test(channel),
    ),
  ).toStrictEqual([]);

  h.emit({ type: "session_shutdown", reason: "quit" }, h.context);
});

it("replaces directory and diagnostic scope with the runtime context", async () => {
  const h = harness();
  const tui = { requestRender: vi.fn<() => void>() };

  const footerData = {
    getExtensionStatuses: () => new Map<string, string>(),
    onBranchChange: () => () => {},
  };

  h.emit({ type: "session_start", reason: "startup" }, h.context);

  const firstFactory = h.setFooter.mock.lastCall?.[0];

  if (!firstFactory) {
    throw new Error("Expected the first footer factory");
  }

  const first = firstFactory(tui, h.context.ui.theme, footerData);

  h.events.emit("pilens:diagnostics", {
    v: 1,
    cwd: h.context.cwd,
    seq: 1,
    files: [
      {
        path: "old.ts",
        diagnostics: [{ severity: "error", message: "Old root" }],
      },
    ],
  });

  expect(first.render(240)[1]).toContain("1E 0W");

  const replacement = { ...h.context, cwd: "/replacement-footer-fixture" };

  h.emit({ type: "session_start", reason: "resume" }, replacement);
  first.dispose?.();

  const secondFactory = h.setFooter.mock.lastCall?.[0];

  if (!secondFactory) {
    throw new Error("Expected the replacement footer factory");
  }

  const second = secondFactory(tui, replacement.ui.theme, footerData);

  h.events.emit("pilens:diagnostics", {
    v: 1,
    cwd: h.context.cwd,
    seq: 2,
    files: [
      {
        path: "old.ts",
        diagnostics: [{ severity: "error", message: "Late old root" }],
      },
    ],
  });

  expect(second.render(240)).toStrictEqual([
    expect.stringContaining(replacement.cwd),
    expect.not.stringContaining("1E"),
  ]);

  h.emit({ type: "session_shutdown", reason: "quit" }, replacement);
});

it.each(["rpc", "json", "print"] as const)(
  "does not mount terminal components or start timers in %s mode",
  async (mode) => {
    const h = harness(mode);

    h.emit({ type: "session_start", reason: "startup" }, h.context);

    expect(h.setFooter).not.toHaveBeenCalled();
    expect(h.runtime.clock.pending).toBe(0);

    h.emit({ type: "session_shutdown", reason: "quit" }, h.context);

    expect(h.channels.size).toBe(0);
  },
);
