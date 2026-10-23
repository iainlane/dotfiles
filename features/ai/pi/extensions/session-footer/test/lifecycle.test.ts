import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { ProcessTerminal, TuiMainScreen } from "@earendil-works/pi-tui";
import extension from "../src/extension.ts";
import { record } from "../src/text.ts";

type Handler = (
  event: unknown,
  context: ExtensionContext,
) => void | Promise<unknown>;

function harness(mode = "tui") {
  const handlers = new Map<string, Handler>();
  const channels = new Map<string, Set<(value: unknown) => void>>();
  const emitted: string[] = [];
  const events = {
    on(channel: string, callback: (value: unknown) => void) {
      const listeners = channels.get(channel) ?? new Set();

      listeners.add(callback);
      channels.set(channel, listeners);

      return () => {
        listeners.delete(callback);

        if (!listeners.size) channels.delete(channel);
      };
    },
    emit(channel: string, raw: unknown) {
      emitted.push(channel);

      for (const callback of channels.get(channel) ?? []) callback(raw);

      if (
        channel === "sub-core:request" &&
        record(raw) &&
        typeof raw.reply === "function"
      ) {
        raw.reply({
          state: {
            provider: "codex",
            usage: {
              lastSuccessAt: Date.now(),
              windows: [{ label: "Week", usedPercent: 2 }],
            },
          },
        });
      }

      if (channel === "subagents:rpc:v1:request" && record(raw)) {
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
  const setFooter = vi.fn<ExtensionContext["ui"]["setFooter"]>();
  const context = {
    mode,
    cwd: "/nonexistent-footer-fixture",
    thinkingLevel: "high",
    model: { provider: "openai-codex", id: "fixture", contextWindow: 200_000 },
    ui: {
      setFooter,
      notify: vi.fn(),
      theme: {
        fg: (_role: string, value: string) => value,
        bold: (value: string) => value,
      },
    },
    getContextUsage: () => undefined,
    hasPendingMessages: () => false,
    sessionManager: {
      getHeader: () => null,
      getBranch: () => [],
      getEntries: () => [],
      getLeafId: () => null,
    },
  } as unknown as ExtensionContext;
  const api = {
    events,
    on(name: string, callback: Handler) {
      handlers.set(name, callback);

      return () => {
        handlers.delete(name);
      };
    },
    registerCommand: vi.fn(),
  } as unknown as ExtensionAPI;

  extension(api);

  return { context, handlers, channels, emitted, setFooter, events };
}

afterEach(() => vi.useRealTimers());

it.each(["sub-core:ready", "sub-core:update-current"])(
  "keeps fresh quota updates between clock ticks available on %s",
  async (channel) => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-20T12:00:00Z"));

    const h = harness();

    await h.handlers.get("session_start")?.({ reason: "startup" }, h.context);

    const factory = h.setFooter.mock.lastCall?.[0];

    if (!factory) throw new Error("Expected the session footer factory");

    const tui = new TuiMainScreen(new ProcessTerminal());

    vi.spyOn(tui, "requestRender").mockImplementation(() => {});

    const view = factory(tui, h.context.ui.theme, {
      getGitBranch: () => null,
      getExtensionStatuses: () => new Map(),
      getAvailableProviderCount: () => 1,
      onBranchChange: () => () => {},
    });
    const readings: string[] = [];

    for (const delay of [250, 1000, 5000]) {
      await vi.advanceTimersByTimeAsync(delay);
      h.events.emit(channel, {
        state: {
          provider: "codex",
          usage: {
            lastSuccessAt: Date.now(),
            windows: [{ label: "Week", usedPercent: 42 }],
          },
        },
      });
      readings.push(view.render(120)[1]?.trim() ?? "");
    }

    expect(readings).toStrictEqual(
      Array(3).fill(" week 42% used  $0.00  0m"),
    );

    await h.handlers.get("session_shutdown")?.({ reason: "quit" }, h.context);
  },
);

it("reconnects sources after session replacement and never enables PR automation", async () => {
  vi.useFakeTimers();

  const h = harness();

  await h.handlers.get("session_start")?.({ reason: "startup" }, h.context);
  await Promise.resolve();

  const connected = h.channels.size;

  expect(h.setFooter).toHaveBeenCalledTimes(1);

  await h.handlers.get("session_shutdown")?.({ reason: "new" }, h.context);

  expect(h.channels.size).toBe(0);
  expect(vi.getTimerCount()).toBe(0);

  await h.handlers.get("session_start")?.({ reason: "new" }, h.context);
  await Promise.resolve();

  expect(h.channels.size).toBe(connected);
  expect(h.setFooter).toHaveBeenCalledTimes(2);
  expect(
    h.emitted.filter((channel) =>
      /feedback|ci-failure|sub-core:action/.test(channel),
    ),
  ).toStrictEqual([]);

  await h.handlers.get("session_shutdown")?.({ reason: "quit" }, h.context);
});

it("replaces directory and diagnostic scope with the runtime context", async () => {
  vi.useFakeTimers();

  const h = harness();
  const tui = new TuiMainScreen(new ProcessTerminal());

  vi.spyOn(tui, "requestRender").mockImplementation(() => {});

  const footerData = {
    getGitBranch: () => null,
    getExtensionStatuses: () => new Map<string, string>(),
    getAvailableProviderCount: () => 1,
    onBranchChange: () => () => {},
  };

  await h.handlers.get("session_start")?.({ reason: "startup" }, h.context);

  const firstFactory = h.setFooter.mock.lastCall?.[0];

  if (!firstFactory) throw new Error("Expected the first footer factory");

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

  await h.handlers.get("session_start")?.({ reason: "resume" }, replacement);
  first.dispose?.();

  const secondFactory = h.setFooter.mock.lastCall?.[0];

  if (!secondFactory)
    throw new Error("Expected the replacement footer factory");

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

  await h.handlers.get("session_shutdown")?.({ reason: "quit" }, replacement);
});

it.each(["rpc", "json", "print"])(
  "does not mount terminal components or start timers in %s mode",
  async (mode) => {
    vi.useFakeTimers();

    const h = harness(mode);

    await h.handlers.get("session_start")?.({ reason: "startup" }, h.context);

    expect(h.setFooter).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);

    await h.handlers.get("session_shutdown")?.({ reason: "quit" }, h.context);

    expect(h.channels.size).toBe(0);
  },
);
