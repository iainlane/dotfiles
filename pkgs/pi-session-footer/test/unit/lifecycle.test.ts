import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { KeybindingsManager } from "#test/support/keybindings.ts";

import { isReply } from "#test/support/requests.ts";
import { expect, it, vi } from "vitest";
import {
  createFooter,
  type FooterUIContext,
  type FooterView,
} from "#footer/application/controller.ts";
import { dependencies } from "#test/support/dependencies.ts";
import { record } from "#footer/shared/text.ts";
import { editorFixture } from "#test/support/editor.ts";
import { loadSettings } from "#footer/configuration/settings.ts";
import { runtimeFixture } from "#test/support/runtime.ts";
import { parseGitStatus } from "#footer/integrations/git.ts";
import type { Component } from "@earendil-works/pi-tui";

type EditorFactory = NonNullable<
  ReturnType<ExtensionUIContext["getEditorComponent"]>
>;

const pretty: EditorFactory = () => {
  throw new Error("Not rendered by this fixture");
};
const later: EditorFactory = () => {
  throw new Error("Not rendered by this fixture");
};

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
  let editor: EditorFactory | undefined;
  const setEditorComponent = vi.fn<FooterUIContext["ui"]["setEditorComponent"]>(
    (factory) => {
      editor = factory;
    },
  );
  const context: FooterUIContext = {
    mode,
    cwd: "/footer-fixture",
    model: { id: "fixture", provider: "openai", contextWindow: 200_000 },
    thinkingLevel: "high",
    getContextUsage: (): undefined => {},
    hasPendingMessages: () => false,
    sessionManager: {
      getHeader: () => ({ timestamp: "2026-10-20T12:00:00Z" }),
      getEntries: () => [],
      getBranch: () => [],
      getLeafId: () => null,
    },
    ui: {
      theme: {
        fg: (_role, value) => value,
        bold: (value) => value,
        style: (value) => value,
      },
      select: async (): Promise<undefined> => {},
      notify: vi.fn<FooterUIContext["ui"]["notify"]>(),
      custom: async () => {},
      setFooter,
      setWidget() {},
      setEditorComponent,
      getEditorComponent: () => editor,
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
    setEditorComponent,
    events,
    footer,
    runtime,
  };
}

it("loads active local preferences through the injected settings store", () => {
  const h = harness();
  const source = h.runtime.settingsStore.load();
  const loaded = loadSettings(() => '{"preset":"minimal"}', source.userPath);
  h.runtime.settingsStore.load.mockReturnValue({
    ...source,
    loaded,
    userExists: true,
  });
  h.footer.start(h.context);
  const factory = h.setFooter.mock.lastCall?.[0];
  if (!factory) {
    throw new Error("Expected the footer factory");
  }
  const view = factory({ requestRender() {} }, h.context.ui.theme, {
    getExtensionStatuses: () => new Map(),
    onBranchChange: () => () => {},
  });
  const display = view.render(200).join("\n");
  expect({
    directory: display.includes(""),
    model: display.includes(""),
    writes: h.runtime.settingsStore.save.mock.calls,
  }).toStrictEqual({ directory: true, model: false, writes: [] });
  h.footer.shutdown();
});

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
      Array.from({ length: 3 }, () => " ◴ week 42%"),
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

  expect(first.render(240)[1]).toContain("⊗1 ⚠0");

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
    expect.not.stringContaining("⊗1"),
  ]);

  h.emit({ type: "session_shutdown", reason: "quit" }, replacement);
});

it("captures one clock/status observation for both composer borders and its explanation", async () => {
  const h = harness();
  h.runtime.readSettings.mockReturnValue(
    JSON.stringify({
      "top-left": ["age", "statuses"],
      "top-right": [],
      "bottom-left": ["age", "statuses"],
      "bottom-right": [],
    }),
  );
  h.context.sessionManager.getEntries = () => [
    { id: "usage", type: "usage", usage: { input: 1 } },
  ];
  h.footer.start(h.context);
  const footerFactory = h.setFooter.mock.lastCall?.[0];
  if (!footerFactory) {
    throw new Error("Expected footer factory");
  }
  let statusReads = 0;
  footerFactory({ requestRender() {} }, h.context.ui.theme, {
    onBranchChange: () => () => {},
    getExtensionStatuses: () =>
      new Map([["source", ++statusReads === 1 ? "first" : "second"]]),
  });
  h.footer.mountComposer(h.context);
  const factory = h.context.ui.getEditorComponent();
  if (!factory) {
    throw new Error("Expected editor factory");
  }
  const { tui, theme, keys } = editorFixture();
  const editor = factory(tui, theme, keys);
  const start = h.runtime.clock.now();
  vi.spyOn(h.runtime.clock, "now")
    .mockReturnValueOnce(start + 59_999)
    .mockReturnValue(start + 60_000);
  const rendered = editor.render(100);
  expect({
    statusReads,
    top: rendered[0]?.includes(" 0m"),
    bottom: rendered.at(-1)?.includes(" 0m"),
    second: rendered.join(" ").includes("second"),
  }).toStrictEqual({ statusReads: 1, top: true, bottom: true, second: false });
  let explanation: string[] = [];
  let technical: string[] = [];
  h.context.ui.custom = async (create) => {
    const view = create(
      { terminal: { rows: 40 }, requestRender() {} },
      h.context.ui.theme,
      keys,
      () => {},
    );
    explanation = view.render(160);
    view.handleInput("\u001B[B");
    view.handleInput("\u001B[B");
    view.handleInput("\r");
    technical = view.render(160);
    view.dispose();
  };
  await h.footer.inspect("explain age", h.context);
  expect({
    capturedTime: technical
      .join(" ")
      .includes(new Date(start + 59_999).toISOString()),
    oldAge: explanation.join(" ").includes(" 0m"),
    newAge: explanation.join(" ").includes(" 1m"),
  }).toStrictEqual({ capturedTime: true, oldAge: true, newAge: false });
  h.footer.shutdown();
});

function countPaints(h: ReturnType<typeof harness>) {
  const paints = {
    count: 0,
    paint: (_role: string, value: string) => value,
  };
  h.context.ui.theme.fg = (role, value) => {
    paints.count++;
    return paints.paint(role, value);
  };
  return paints;
}

function fallbackView(
  h: ReturnType<typeof harness>,
  statuses = new Map<string, string>(),
) {
  const factory = h.setFooter.mock.lastCall?.[0];
  if (!factory) {
    throw new Error("Expected the footer factory");
  }
  return () =>
    factory({ requestRender() {} }, h.context.ui.theme, {
      getExtensionStatuses: () => statuses,
      onBranchChange: () => () => {},
    });
}

it("reuses the fallback layout while nothing displayed changes", async () => {
  const h = harness();
  const paints = countPaints(h);
  h.footer.start(h.context);
  const view = fallbackView(h)();
  await h.runtime.clock.advance(0);
  const first = view.render(120);
  paints.count = 0;

  expect({ lines: view.render(120), paints: paints.count }).toStrictEqual({
    lines: first,
    paints: 0,
  });
  h.footer.shutdown();
});

it("reuses the composer borders while nothing displayed changes", async () => {
  const h = harness();
  const paints = countPaints(h);
  h.footer.start(h.context);
  fallbackView(h)();
  h.footer.mountComposer(h.context);
  const factory = h.context.ui.getEditorComponent();
  if (!factory) {
    throw new Error("Expected editor factory");
  }
  const { tui, theme, keys } = editorFixture();
  const editor = factory(tui, theme, keys);
  await h.runtime.clock.advance(0);
  const first = editor.render(100);
  paints.count = 0;
  const second = editor.render(100);
  const unchanged = paints.count;
  paints.paint = (_role, value) => `[${value}]`;
  editor.invalidate();

  expect({
    second,
    unchanged,
    themed: editor.render(100)[0]?.includes("[") ?? false,
  }).toStrictEqual({ second: first, unchanged: 0, themed: true });
  h.footer.shutdown();
});

it.each<{
  trigger: string;
  width?: number;
  repaint: boolean;
  change: (
    h: ReturnType<typeof harness>,
    view: FooterView,
    statuses: Map<string, string>,
    paints: ReturnType<typeof countPaints>,
  ) => Promise<void> | void;
}>([
  { trigger: "a width change", width: 100, repaint: true, change: () => {} },
  {
    trigger: "a quota update",
    repaint: true,
    change: (h) => {
      h.events.emit("sub-core:update-current", {
        state: {
          provider: "codex",
          usage: {
            lastSuccessAt: h.runtime.clock.now(),
            windows: [{ label: "Week", usedPercent: 42 }],
          },
        },
      });
    },
  },
  {
    trigger: "an extension status change",
    repaint: true,
    change: (_h, _view, statuses) => {
      statuses.set("source", "changed");
    },
  },
  {
    trigger: "a theme change",
    repaint: true,
    change: (_h, view, _statuses, paints) => {
      paints.paint = (_role, value) => `[${value}]`;
      view.invalidate();
    },
  },
  {
    trigger: "a model selection",
    repaint: true,
    change: (h) => {
      h.context.model = {
        id: "replacement",
        provider: "openai",
        contextWindow: 200_000,
      };
      h.footer.selectModel(h.context);
    },
  },
  {
    trigger: "a minute boundary while idle",
    repaint: true,
    change: async (h) => {
      await h.runtime.clock.advance(60_000);
    },
  },
  {
    trigger: "a minute boundary while running",
    repaint: true,
    change: async (h) => {
      h.footer.startAgent(h.context);
      await h.runtime.clock.advance(60_000);
    },
  },
  {
    trigger: "a second within the same idle minute",
    repaint: false,
    change: async (h) => {
      await h.runtime.clock.advance(1000);
    },
  },
])(
  "repaints the fallback footer after $trigger",
  async ({ width = 120, repaint, change }) => {
    const h = harness();
    const paints = countPaints(h);
    const statuses = new Map([["source", "initial"]]);
    h.footer.start(h.context);
    const create = fallbackView(h, statuses);
    const view = create();
    await h.runtime.clock.advance(0);
    const before = view.render(120);
    paints.count = 0;
    await change(h, view, statuses, paints);
    const after = view.render(width);
    const painted = paints.count > 0;

    expect({
      painted,
      changed: JSON.stringify(after) !== JSON.stringify(before),
      after,
    }).toStrictEqual({
      painted: repaint,
      changed: repaint,
      after: create().render(width),
    });
    h.footer.shutdown();
  },
);

it("restores a known PR when Git returns to its branch", async () => {
  const h = harness();
  const branch = (name: string) => ({
    ...parseGitStatus(`# branch.head ${name}`, h.runtime.clock.now()),
    root: h.context.cwd,
  });
  h.runtime.readGit.mockResolvedValue(branch("main"));
  h.footer.start(h.context);
  const view = fallbackView(h)();
  await h.runtime.clock.advance(0);
  h.events.emit("pr:state", {
    protocol: 1,
    source: "pi-prs",
    repository: "a/b",
    branch: "main",
    health: "ok",
    updatedAt: 10,
    pullRequest: {
      target: { number: 7 },
      lifecycle: "open",
      mergeState: "mergeable",
      unresolvedThreadCount: 0,
    },
  });
  const shown = () => view.render(200).join("\n").includes("#7");
  const checkout = async (name: string) => {
    h.runtime.readGit.mockResolvedValue(branch(name));
    h.footer.endTool("tool");
    await h.runtime.clock.advance(0);
    return shown();
  };
  const initial = shown();
  const away = await checkout("feature");
  const back = await checkout("main");

  expect({ initial, away, back }).toStrictEqual({
    initial: true,
    away: false,
    back: true,
  });
  h.footer.shutdown();
});

it.each([true, false])(
  "mounts after Pretty with footer started first=%s",
  (footerFirst) => {
    const h = harness();

    if (footerFirst) {
      h.footer.start(h.context);
    }
    h.context.ui.setEditorComponent(pretty);
    if (!footerFirst) {
      h.footer.start(h.context);
    }

    const factory = h.setFooter.mock.lastCall?.[0];
    if (!factory) {
      throw new Error("Expected the footer factory");
    }
    const view = factory({ requestRender() {} }, h.context.ui.theme, {
      getExtensionStatuses: () => new Map(),
      onBranchChange: () => () => {},
    });
    const original = view.render(120);
    h.footer.mountComposer(h.context);
    const ours = h.context.ui.getEditorComponent();
    h.footer.mountComposer(h.context);
    const compact = view.render(120);
    h.context.ui.setEditorComponent(pretty);

    expect({
      different: ours !== pretty,
      compact,
      fallback: view.render(120),
      installations: h.setEditorComponent.mock.calls.length,
    }).toStrictEqual({
      different: true,
      compact: [],
      fallback: original,
      installations: 3,
    });
    h.footer.shutdown();
  },
);

it.each([true, false])(
  "cleans up safely with Pretty shutdown first=%s",
  (prettyFirst) => {
    const h = harness();
    h.footer.start(h.context);
    h.context.ui.setEditorComponent(pretty);
    h.footer.mountComposer(h.context);

    if (prettyFirst) {
      h.context.ui.setEditorComponent(undefined);
    }
    h.footer.shutdown();
    const restored = h.context.ui.getEditorComponent();
    if (!prettyFirst) {
      h.context.ui.setEditorComponent(undefined);
    }

    expect({
      editor: h.context.ui.getEditorComponent(),
      restored,
      listeners: h.channels.size,
      timers: h.runtime.clock.pending,
    }).toStrictEqual({
      editor: undefined,
      restored: prettyFirst ? undefined : pretty,
      listeners: 0,
      timers: 0,
    });
  },
);

it("leaves a later editor intact during shutdown", () => {
  const h = harness();
  h.footer.start(h.context);
  h.footer.mountComposer(h.context);
  h.context.ui.setEditorComponent(later);
  h.footer.shutdown();

  expect(h.context.ui.getEditorComponent()).toBe(later);
});

it("keeps shared session state alive when its footer view is disposed", async () => {
  const h = harness();
  h.footer.start(h.context);
  const factory = h.setFooter.mock.lastCall?.[0];
  if (!factory) {
    throw new Error("Expected the footer factory");
  }
  const redraw = vi.fn<() => void>();
  const view = factory({ requestRender: redraw }, h.context.ui.theme, {
    getExtensionStatuses: () => new Map(),
    onBranchChange: () => () => {},
  });
  h.footer.mountComposer(h.context);
  view.dispose();
  h.events.emit("sub-core:update-current", {
    state: {
      provider: "codex",
      usage: {
        lastSuccessAt: h.runtime.clock.now(),
        windows: [{ label: "Week", usedPercent: 42 }],
      },
    },
  });
  await h.runtime.clock.advance(0);

  expect({
    redraw: redraw.mock.calls.length > 0,
    alive: h.runtime.clock.pending > 0,
  }).toStrictEqual({ redraw: true, alive: true });
  h.footer.shutdown();
});

it.each(["rpc", "json", "print"] as const)(
  "does not mount terminal components or start timers in %s mode",
  async (mode) => {
    const h = harness(mode);

    h.emit({ type: "session_start", reason: "startup" }, h.context);

    h.footer.mountComposer(h.context);

    expect({
      footer: h.setFooter.mock.calls,
      editor: h.setEditorComponent.mock.calls,
      timers: h.runtime.clock.pending,
    }).toStrictEqual({ footer: [], editor: [], timers: 0 });

    h.emit({ type: "session_shutdown", reason: "quit" }, h.context);

    expect(h.channels.size).toBe(0);
  },
);

it("requests structured status on every start, rejects cross-session events and clears on shutdown", () => {
  const h = harness();
  let id = "one";
  h.context.sessionManager.getSessionId = () => id;
  const publish = (active: boolean, text?: string, sessionId = id) =>
    h.events.emit("dotfiles:status:v1", {
      version: 1,
      source: "planning",
      sessionId,
      active,
      text,
    });
  h.events.on("dotfiles:status:request:v1", () => publish(true));
  h.footer.start(h.context);
  const factory = h.setFooter.mock.lastCall?.[0];
  if (!factory) {
    throw new Error("Missing footer");
  }
  const view = factory({ requestRender() {} }, h.context.ui.theme, {
    getExtensionStatuses: () => new Map([["planning", "plan mode on"]]),
    onBranchChange: () => () => {},
  });
  expect(view.render(200).join("\n")).toContain("≡");
  expect(view.render(200).join("\n")).not.toContain("plan mode on");
  publish(true, "editing");
  expect(view.render(200).join("\n")).toContain("≡ editing");
  publish(false, undefined, "wrong");
  h.events.emit("dotfiles:status:v1", {
    version: 2,
    source: "planning",
    sessionId: id,
    active: false,
  });
  expect(view.render(200).join("\n")).toContain("≡ editing");
  publish(false);
  expect(view.render(200).join("\n")).not.toMatch(/≡|plan mode on/);
  id = "two";
  h.footer.start(h.context);
  expect(
    h.emitted.filter((channel) => channel === "dotfiles:status:request:v1"),
  ).toHaveLength(2);
  h.footer.shutdown();
  expect(h.channels.has("dotfiles:status:v1")).toBe(false);
});

it("retains effective source symbols in live profile previews without saving", async () => {
  const h = harness();
  h.runtime.readSettings.mockReturnValue('{"symbols":{"planning":"[P]"}}');
  h.context.sessionManager.getSessionId = () => "one";
  h.footer.start(h.context);
  h.events.emit("dotfiles:status:v1", {
    version: 1,
    source: "planning",
    sessionId: "one",
    active: true,
  });
  const factory = h.setFooter.mock.lastCall?.[0];
  if (!factory) {
    throw new Error("Missing footer");
  }
  factory({ requestRender() {} }, h.context.ui.theme, {
    getExtensionStatuses: () => new Map(),
    onBranchChange: () => () => {},
  }).render(200);
  const native = editorFixture();
  const { context } = await runtimeFixture();
  let view: (Component & { dispose?(): void }) | undefined;
  h.context.ui.setWidget = (_key, content) => {
    view =
      typeof content === "function"
        ? content(native.tui, context.ui.theme)
        : undefined;
  };
  h.footer.mountComposer(h.context);
  const createEditor = h.context.ui.getEditorComponent();
  if (!createEditor) {
    throw new Error("Missing editor factory");
  }
  const editor = createEditor(
    native.tui,
    native.theme,
    new KeybindingsManager({ "tui.select.down": "j" }),
  );
  editor.render(200);
  const opened = h.footer.inspect("config", h.context);
  if (!view) {
    throw new Error("Missing customiser");
  }
  view.render(200);
  view.handleInput?.("\r");
  view.render(200);
  for (let count = 0; count < 3; count++) {
    view.handleInput?.("j");
  }
  expect({
    screen: view.render(200).join("\n").includes("Workflow"),
    symbol: editor.render(200).join("\n").includes("[P]"),
    writes: h.runtime.settingsStore.save.mock.calls,
  }).toStrictEqual({ screen: true, symbol: true, writes: [] });
  view.handleInput?.("\u001B");
  view.handleInput?.("\u001B");
  await opened;
  expect(h.context.ui.getEditorComponent()).toBe(createEditor);
  h.footer.shutdown();
});

it.each(["shutdown", "restart", "inspect"] as const)(
  "discards the customiser on %s and ignores its stale controls",
  async (action) => {
    const h = harness();
    const native = editorFixture();
    const { context } = await runtimeFixture();
    let widget: (Component & { dispose?(): void }) | undefined;
    h.context.ui.setWidget = (_key, content) => {
      widget =
        typeof content === "function"
          ? content(native.tui, context.ui.theme)
          : undefined;
    };
    h.footer.start(h.context);
    h.footer.mountComposer(h.context);
    const create = h.context.ui.getEditorComponent();
    if (!create) {
      throw new Error("Missing editor factory");
    }
    const editor = create(native.tui, native.theme, native.keys);
    editor.render(200);
    const opened = h.footer.inspect("config", h.context);
    const stale = widget;
    if (!stale) {
      throw new Error("Missing customiser");
    }
    stale.render(200);
    stale.handleInput?.("\r");
    stale.render(200);
    stale.handleInput?.("\u001B[B");
    stale.handleInput?.("\u001B[B");
    expect(editor.render(200).join("\n")).not.toContain("");
    switch (action) {
      case "shutdown":
        h.footer.shutdown();
        break;
      case "restart":
        h.footer.start(h.context);
        h.footer.mountComposer(h.context);
        break;
      case "inspect":
        await h.footer.inspect("help", h.context);
        break;
    }
    await opened;
    const current = h.context.ui.getEditorComponent();
    const changes = h.setEditorComponent.mock.calls.length;
    stale.handleInput?.("\r");
    stale.handleInput?.("\u001B");
    stale.render(200);
    expect({
      writes: h.runtime.settingsStore.save.mock.calls,
      factory: h.context.ui.getEditorComponent() === current,
      replacements: h.setEditorComponent.mock.calls.length - changes,
      widget,
    }).toStrictEqual({
      writes: [],
      factory: true,
      replacements: 0,
      widget: undefined,
    });
    h.footer.shutdown();
  },
);
