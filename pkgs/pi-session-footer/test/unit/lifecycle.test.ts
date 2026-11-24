import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { KeybindingsManager } from "#test/support/keybindings.ts";

import { isReply } from "#test/support/requests.ts";
import { expect, it } from "vitest";
import {
  createFooter,
  type FooterUIContext,
  type FooterView,
} from "#footer/application/controller.ts";
import { dependencies } from "#test/support/dependencies.ts";
import { record } from "#footer/shared/text.ts";
import { editorFixture } from "#test/support/editor.ts";
import { FakeScreen } from "#test/support/screen.ts";
import { runtimeFixture } from "#test/support/runtime.ts";
import { gitState } from "#test/support/git.ts";
import type { Component } from "@earendil-works/pi-tui";

type EditorFactory = NonNullable<
  ReturnType<ExtensionUIContext["getEditorComponent"]>
>;
type FooterFactory = Parameters<FooterUIContext["ui"]["setFooter"]>[0];

const pretty: EditorFactory = () => {
  throw new Error("Not rendered by this fixture");
};
const later: EditorFactory = () => {
  throw new Error("Not rendered by this fixture");
};

function harness(mode = "tui") {
  const channels = new Map<string, Set<(value: unknown) => void>>();
  const published = new Map<string, unknown>();
  const agents = { totalActive: 0 };
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
      published.set(channel, raw);

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
            fleet: {
              version: 1,
              totalActive: agents.totalActive,
              entries: [],
              omitted: 0,
            },
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
  let footerFactory: FooterFactory | undefined;
  let editor: EditorFactory | undefined;
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
      notify() {},
      custom: async () => {},
      setFooter: (factory) => {
        footerFactory = factory;
      },
      setWidget() {},
      setEditorComponent: (factory) => {
        editor = factory;
      },
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
    agents,
    context,
    emit,
    channels,
    published,
    installedFooter: () => {
      if (!footerFactory) {
        throw new Error("Expected the footer factory");
      }
      return footerFactory;
    },
    footerInstalled: () => footerFactory !== undefined,
    events,
    footer,
    runtime,
  };
}

it("loads active local preferences through the injected settings store", () => {
  const h = harness();
  h.runtime.settingsStore.stored = '{"preset":"minimal"}';
  h.footer.start(h.context);
  const factory = h.installedFooter();
  const view = factory({ requestRender() {} }, h.context.ui.theme, {
    getExtensionStatuses: () => new Map(),
    onBranchChange: () => () => {},
  });
  expect({
    display: view.render(200),
    stored: h.runtime.settingsStore.stored,
  }).toStrictEqual({
    display: [
      " /footer-fixture                                                                                                                                                                                ◫ 200k",
    ],
    stored: '{"preset":"minimal"}',
  });
  h.footer.shutdown();
});

it.each(["sub-core:ready", "sub-core:update-current"])(
  "keeps fresh quota updates between clock ticks available on %s",
  async (channel) => {
    const h = harness();

    h.emit({ type: "session_start", reason: "startup" }, h.context);

    const factory = h.installedFooter();

    const tui = { requestRender() {} };

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

  const factory = h.installedFooter();

  let view: FooterView | undefined;
  let screen: string[] = [];
  const tui = {
    requestRender() {
      if (view) {
        screen = view.render(200);
      }
    },
  };

  view = factory(tui, h.context.ui.theme, {
    getExtensionStatuses: () => new Map(),
    onBranchChange: () => () => {},
  });

  h.footer.endMessage(h.context, true);
  const failed = screen;

  h.footer.settleAgent(h.context, false);
  const settled = screen;

  h.footer.endMessage(h.context, true);
  h.footer.settleAgent(h.context, true);
  const cancelled = screen;

  expect({ failed, settled, cancelled }).toStrictEqual({
    failed: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      "✗ run failed                                                                                                                                                                                  ◴ week 2%",
    ],
    settled: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      "✗ run failed                                                                                                                                                                                  ◴ week 2%",
    ],
    cancelled: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      "⊘ run cancelled                                                                                                                                                                               ◴ week 2%",
    ],
  });

  h.emit({ type: "session_shutdown", reason: "quit" }, h.context);
});

it("reconnects sources after session replacement and never enables PR automation", async () => {
  const h = harness();

  h.emit({ type: "session_start", reason: "startup" }, h.context);
  await Promise.resolve();

  const connected = h.channels.size;
  const first = h.installedFooter();

  h.emit({ type: "session_shutdown", reason: "new" }, h.context);

  expect(h.channels.size).toBe(0);
  expect(h.runtime.clock.pending).toBe(0);

  h.emit({ type: "session_start", reason: "new" }, h.context);
  await Promise.resolve();

  expect(h.channels.size).toBe(connected);
  expect(h.installedFooter()).not.toBe(first);
  expect(
    [...h.published.keys()].filter((channel) =>
      /feedback|ci-failure|sub-core:action/.test(channel),
    ),
  ).toStrictEqual([]);

  h.emit({ type: "session_shutdown", reason: "quit" }, h.context);
});

it("replaces directory and diagnostic scope with the runtime context", async () => {
  const h = harness();
  const tui = { requestRender() {} };

  const footerData = {
    getExtensionStatuses: () => new Map<string, string>(),
    onBranchChange: () => () => {},
  };

  h.emit({ type: "session_start", reason: "startup" }, h.context);

  const firstFactory = h.installedFooter();

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

  expect(first.render(240)).toStrictEqual([
    " openai/fixture   /footer-fixture                                                                                                                                                                                                     ◫ 200k",
    "⊗1 ⚠0                                                                                                                                                                                                                                 ◴ week 2%",
  ]);

  const replacement = { ...h.context, cwd: "/replacement-footer-fixture" };

  h.emit({ type: "session_start", reason: "resume" }, replacement);
  first.dispose?.();

  const secondFactory = h.installedFooter();

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
    " openai/fixture   /replacement-footer-fixture                                                                                                                                                                                         ◫ 200k",
    "                                                                                                                                                                                                                                      ◴ week 2%",
  ]);

  h.emit({ type: "session_shutdown", reason: "quit" }, replacement);
});

it("captures one clock/status observation for both composer borders and its explanation", async () => {
  const h = harness();
  h.runtime.settingsStore.stored = JSON.stringify({
    "top-left": ["age", "statuses"],
    "top-right": [],
    "bottom-left": ["age", "statuses"],
    "bottom-right": [],
  });
  h.context.sessionManager.getEntries = () => [
    { id: "usage", type: "usage", usage: { input: 1 } },
  ];
  h.footer.start(h.context);
  const footerFactory = h.installedFooter();
  const start = h.runtime.clock.now();
  footerFactory({ requestRender() {} }, h.context.ui.theme, {
    onBranchChange: () => () => {},
    getExtensionStatuses: () =>
      new Map([
        ["source", h.runtime.clock.now() < start + 60_000 ? "first" : "second"],
      ]),
  });
  h.footer.mountComposer(h.context);
  const factory = h.context.ui.getEditorComponent();
  if (!factory) {
    throw new Error("Expected editor factory");
  }
  const { tui, theme, keys } = editorFixture();
  const editor = factory(tui, theme, keys);
  h.runtime.clock.set(start + 59_999);
  const rendered = editor.render(100);
  h.runtime.clock.set(start + 60_000);
  let explanation: readonly string[] = [];
  let technical: readonly string[] = [];
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
  expect({ rendered, explanation, technical }).toStrictEqual({
    rendered: [
      "╭─  0m  ◇ source: first──────────────────────────────────────────────────────────────────────── ─╮",
      "│  \u001B_pi:fc\u0007 \u001B_pi:/fc\u0007                                                                                               │",
      "╰─  0m  ◇ source: first──────────────────────────────────────────────────────────────────────── ─╯",
    ],
    explanation: [
      "Footer › Explain › Session age",
      "›  0m  Top left                                                                                                                                                ",
      "   0m  Bottom left                                                                                                                                             ",
      "  Rendering details                                                                                                                                             ",
      "  Open Usage                                                                                                                                                    ",
      "  Sections…                                                                                                                                                     ",
      "enter open · escape/ctrl+c back · s sections",
      "1/5 · up/down move · pageUp/pageDown page",
    ],
    technical: [
      "Footer › Explain › Session age › Rendering details",
      "Captured: 2026-10-20T12:00:59.999Z                                                                                                                              ",
      "Owner: composer                                                                                                                                                 ",
      "Usable columns: top 94, bottom 94                                                                                                                               ",
      "Source symbols:  elapsed wall-clock session age                                                                                                                ",
      "Top left: 94 columns                                                                                                                                            ",
      "Appearance: {}                                                                                                                                                  ",
      "age: variant 1, priority 1                                                                                                                                      ",
      'Symbols: [{"value":"","colour":"dim"}]                                                                                                                         ',
      "Bottom left: 94 columns                                                                                                                                         ",
      "Appearance: {}                                                                                                                                                  ",
      "age: variant 1, priority 1                                                                                                                                      ",
      'Symbols: [{"value":"","colour":"dim"}]                                                                                                                         ',
      "Top left · age: full                                                                                                                                            ",
      "Bottom left · age: full                                                                                                                                         ",
      "Default priority: 1. Full, shortened where supported, then omitted for width.                                                                                   ",
      "escape/ctrl+c back · s sections",
      "1–15/15 · up/down move · pageUp/pageDown page",
    ],
  });
  h.footer.shutdown();
});

function fallbackView(
  h: ReturnType<typeof harness>,
  statuses = new Map<string, string>(),
) {
  const factory = h.installedFooter();
  return () =>
    factory({ requestRender() {} }, h.context.ui.theme, {
      getExtensionStatuses: () => statuses,
      onBranchChange: () => () => {},
    });
}

it("paints the composer borders again after a theme change", async () => {
  const h = harness();
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
  const plain = editor.render(100)[0];
  h.context.ui.theme.fg = (_role, value) => `[${value}]`;
  editor.invalidate();
  const themed = editor.render(100)[0];

  expect({ plain, themed }).toStrictEqual({
    plain:
      "╭─  openai/fixture   /footer-fixture                                                   ◫ 200k ─╮",
    themed:
      "╭─ [ openai/][fixture][  ][ /footer-fixture]                                    [ ][◫ ][200k] ─╮",
  });
  h.footer.shutdown();
});

it.each<{
  trigger: string;
  width?: number;
  changes: boolean;
  change: (
    h: ReturnType<typeof harness>,
    view: FooterView,
    statuses: Map<string, string>,
  ) => Promise<void> | void;
}>([
  { trigger: "a width change", width: 100, changes: true, change: () => {} },
  {
    trigger: "a quota update",
    changes: true,
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
    changes: true,
    change: (_h, _view, statuses) => {
      statuses.set("source", "changed");
    },
  },
  {
    trigger: "a theme change",
    changes: true,
    change: (h, view) => {
      h.context.ui.theme.fg = (_role, value) => `[${value}]`;
      view.invalidate();
    },
  },
  {
    trigger: "a model selection",
    changes: true,
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
    changes: true,
    change: async (h) => {
      await h.runtime.clock.advance(60_000);
    },
  },
  {
    trigger: "a minute boundary while running",
    changes: true,
    change: async (h) => {
      h.footer.startAgent(h.context);
      await h.runtime.clock.advance(60_000);
    },
  },
  {
    trigger: "a second within the same idle minute",
    changes: false,
    change: async (h) => {
      await h.runtime.clock.advance(1000);
    },
  },
])(
  "updates the fallback footer after $trigger",
  async ({ width = 120, changes, change }) => {
    const h = harness();
    h.context.ui.theme.fg = (_role, value) => value;
    const statuses = new Map([["source", "initial"]]);
    h.footer.start(h.context);
    const create = fallbackView(h, statuses);
    const view = create();
    await h.runtime.clock.advance(0);
    const before = view.render(120);
    await change(h, view, statuses);
    const after = view.render(width);

    expect({
      changed: JSON.stringify(after) !== JSON.stringify(before),
      after,
    }).toStrictEqual({
      changed: changes,
      after: create().render(width),
    });
    h.footer.shutdown();
  },
);

it("updates the inspector's quota age on screen while no agent is running", async () => {
  const h = harness();
  const screen = new FakeScreen();
  h.footer.start(h.context);
  const factory = h.installedFooter();
  screen.show(
    factory(screen, h.context.ui.theme, {
      getExtensionStatuses: () => new Map(),
      onBranchChange: () => () => {},
    }),
  );
  const { keys } = editorFixture();
  let view: ReturnType<Parameters<typeof h.context.ui.custom>[0]> | undefined;
  h.context.ui.custom = async (create) => {
    await new Promise<void>((resolve) => {
      const component = create(screen, h.context.ui.theme, keys, () => {
        screen.hide(component);
        resolve();
      });
      view = component;
      screen.show(component);
    });
  };
  const opened = h.footer.inspect("explain", h.context);
  const inspector = view;
  if (!inspector) {
    throw new Error("Expected the inspector");
  }
  inspector.handleInput("\t");
  inspector.handleInput("\t");
  await h.runtime.clock.advance(0);
  const age = () =>
    screen.lines.find((line) => line.startsWith("Updated "))?.trim();
  const before = age();
  await h.runtime.clock.advance(1000);
  const after = age();
  inspector.handleInput("\u001B");
  await opened;

  expect({ before, after }).toStrictEqual({
    before: "Updated 0s ago",
    after: "Updated 1s ago",
  });
  h.footer.shutdown();
});

it("discovers foreground subagents without a lifecycle event and updates their count", async () => {
  const h = harness();
  const screen = new FakeScreen(200);
  h.footer.start(h.context);
  const factory = h.installedFooter();
  screen.show(
    factory(screen, h.context.ui.theme, {
      getExtensionStatuses: () => new Map(),
      onBranchChange: () => () => {},
    }),
  );
  await h.runtime.clock.advance(0);
  h.footer.startTool("delegation", "subagent");
  h.footer.startTool("other", "bash");
  h.agents.totalActive = 2;
  await h.runtime.clock.advance(2000);
  h.footer.endTool("delegation");
  h.footer.endTool("other");
  const two = screen.lines;
  h.agents.totalActive = 3;
  await h.runtime.clock.advance(2000);
  const three = screen.lines;

  expect({ two, three }).toStrictEqual({
    two: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      " 2                                                                                                                                                                                           ◴ week 2%",
    ],
    three: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      " 3                                                                                                                                                                                           ◴ week 2%",
    ],
  });
  h.footer.shutdown();
});

it("restores a known PR when Git returns to its branch", async () => {
  const h = harness();
  const branch = (name: string) => ({
    ...gitState(name, h.runtime.clock.now()),
    root: h.context.cwd,
  });
  h.runtime.repository.state = branch("main");
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
  const shown = () => view.render(200);
  const checkout = async (name: string) => {
    h.runtime.repository.state = branch(name);
    h.footer.endTool("tool");
    await h.runtime.clock.advance(0);
    return shown();
  };
  const initial = shown();
  const away = await checkout("feature");
  const back = await checkout("main");

  expect({ initial, away, back }).toStrictEqual({
    initial: [
      " openai/fixture   /footer-fixture   main   #7                                                                                                                                             ◫ 200k",
      "                                                                                                                                                                                              ◴ week 2%",
    ],
    away: [
      " openai/fixture   /footer-fixture   feature                                                                                                                                                 ◫ 200k",
      "                                                                                                                                                                                              ◴ week 2%",
    ],
    back: [
      " openai/fixture   /footer-fixture   main   #7                                                                                                                                             ◫ 200k",
      "                                                                                                                                                                                              ◴ week 2%",
    ],
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

    const factory = h.installedFooter();
    const view = factory({ requestRender() {} }, h.context.ui.theme, {
      getExtensionStatuses: () => new Map(),
      onBranchChange: () => () => {},
    });
    const original = view.render(120);
    h.footer.mountComposer(h.context);
    const ours = h.context.ui.getEditorComponent();
    h.footer.mountComposer(h.context);
    const again = h.context.ui.getEditorComponent();
    const compact = view.render(120);
    h.context.ui.setEditorComponent(pretty);

    expect({
      different: ours !== pretty,
      compact,
      kept: again === ours,
      fallback: view.render(120),
    }).toStrictEqual({
      different: true,
      compact: [],
      kept: true,
      fallback: original,
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
  const screen = new FakeScreen(200);
  h.footer.start(h.context);
  const factory = h.installedFooter();
  const view = factory(screen, h.context.ui.theme, {
    getExtensionStatuses: () => new Map(),
    onBranchChange: () => () => {},
  });
  h.footer.mountComposer(h.context);
  const createEditor = h.context.ui.getEditorComponent();
  if (!createEditor) {
    throw new Error("Expected editor factory");
  }
  const { tui, theme, keys } = editorFixture();
  screen.show(createEditor(tui, theme, keys));
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
    screen: screen.lines,
    alive: h.runtime.clock.pending > 0,
  }).toStrictEqual({
    screen: [
      "╭─  openai/fixture   /footer-fixture                                                                                                                                                       ◫ 200k ─╮",
      "│  \u001B_pi:fc\u0007 \u001B_pi:/fc\u0007                                                                                                                                                                                                   │",
      "╰─                                                                                                                                                                                        ◴ week 42% ─╯",
    ],
    alive: true,
  });
  h.footer.shutdown();
});

it.each(["rpc", "json", "print"] as const)(
  "does not mount terminal components or start timers in %s mode",
  async (mode) => {
    const h = harness(mode);

    h.emit({ type: "session_start", reason: "startup" }, h.context);

    h.footer.mountComposer(h.context);

    expect({
      footer: h.footerInstalled(),
      editor: h.context.ui.getEditorComponent(),
      timers: h.runtime.clock.pending,
    }).toStrictEqual({ footer: false, editor: undefined, timers: 0 });

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
  const factory = h.installedFooter();
  const view = factory({ requestRender() {} }, h.context.ui.theme, {
    getExtensionStatuses: () => new Map([["planning", "plan mode on"]]),
    onBranchChange: () => () => {},
  });
  const requested = view.render(200);
  publish(true, "editing");
  const editing = view.render(200);
  publish(false, undefined, "wrong");
  h.events.emit("dotfiles:status:v1", {
    version: 2,
    source: "planning",
    sessionId: id,
    active: false,
  });
  const rejected = view.render(200);
  publish(false);
  const inactive = view.render(200);
  id = "two";
  h.footer.start(h.context);
  const restarted = h.installedFooter()(
    { requestRender() {} },
    h.context.ui.theme,
    {
      getExtensionStatuses: () => new Map(),
      onBranchChange: () => () => {},
    },
  );
  const screens = {
    requested,
    editing,
    rejected,
    inactive,
    restarted: restarted.render(200),
  };
  expect(screens).toStrictEqual({
    requested: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      "≡                                                                                                                                                                                             ◴ week 2%",
    ],
    editing: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      "≡ editing                                                                                                                                                                                     ◴ week 2%",
    ],
    rejected: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      "≡ editing                                                                                                                                                                                     ◴ week 2%",
    ],
    inactive: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      "                                                                                                                                                                                              ◴ week 2%",
    ],
    restarted: [
      " openai/fixture   /footer-fixture                                                                                                                                                             ◫ 200k",
      "≡                                                                                                                                                                                             ◴ week 2%",
    ],
  });
  h.footer.shutdown();
  expect(h.channels.has("dotfiles:status:v1")).toBe(false);
});

it("retains effective source symbols in live profile previews without saving", async () => {
  const h = harness();
  h.runtime.settingsStore.stored = '{"symbols":{"planning":"[P]"}}';
  h.context.sessionManager.getSessionId = () => "one";
  h.footer.start(h.context);
  h.events.emit("dotfiles:status:v1", {
    version: 1,
    source: "planning",
    sessionId: "one",
    active: true,
  });
  const factory = h.installedFooter();
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
    screen: view.render(200),
    editor: editor.render(200),
    stored: h.runtime.settingsStore.stored,
  }).toStrictEqual({
    screen: [
      "Footer › Customise › Profile",
      "  Rich                            Identity, workflow and usage",
      "  Compact                         Identity and context",
      "  Minimal                         Directory, Git and context",
      "→ Workflow                        Work and attention",
      "Preview · not saved",
      "enter choose · escape/ctrl+c back",
    ],
    editor: [
      "╭─  openai/fixture   /footer-fixture                                                                                                                                                       ◫ 200k ─╮",
      "│  \u001B_pi:fc\u0007 \u001B_pi:/fc\u0007                                                                                                                                                                                                   │",
      "╰─ [P]                                                                                                                                                                                     ◴ week 2% ─╯",
    ],
    stored: '{"symbols":{"planning":"[P]"}}',
  });
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
    expect(editor.render(200)).toStrictEqual([
      "╭─  /footer-fixture                                                                                                                                                                          ◫ 200k ─╮",
      "╰─ \u001B_pi:fc\u0007 \u001B_pi:/fc\u0007                                                                                                                                                                                                  ─╯",
    ]);
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
    stale.handleInput?.("\r");
    stale.handleInput?.("\u001B");
    stale.render(200);
    expect({
      stored: h.runtime.settingsStore.stored,
      factory: h.context.ui.getEditorComponent() === current,
      widget,
    }).toStrictEqual({
      stored: undefined,
      factory: true,
      widget: undefined,
    });
    h.footer.shutdown();
  },
);

async function composerLines(stored: string): Promise<readonly string[]> {
  const h = harness();
  h.runtime.settingsStore.stored = stored;
  h.footer.start(h.context);
  h.footer.mountComposer(h.context);
  const create = h.context.ui.getEditorComponent();
  if (!create) {
    throw new Error("Missing editor factory");
  }
  const { tui, theme, keys } = editorFixture();
  const editor = create(tui, theme, keys);
  await h.runtime.clock.advance(0);
  const lines = editor.render(200);
  h.footer.shutdown();
  return lines;
}

async function openCustomiser(h: ReturnType<typeof harness>) {
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
  const view = () => {
    if (!widget) {
      throw new Error("Missing customiser");
    }
    return widget;
  };
  const screen = () => view().render(200).join("\n");
  const choose = (label: string) => {
    for (let attempts = 0; attempts < 100; attempts++) {
      if (screen().includes(`→ ${label}`)) {
        view().handleInput?.("\r");
        return;
      }
      view().handleInput?.("\u001B[B");
    }
    throw new Error(`Missing selectable action: ${label}\n${screen()}`);
  };
  return {
    editor,
    opened,
    screen,
    choose,
    cancel: () => view().handleInput?.("\u001B"),
    open: () => widget !== undefined,
  };
}

it("keeps a draft open after a failed save and uses it for the session on request", async () => {
  const h = harness();
  h.runtime.settingsStore.failure = Object.assign(
    new Error("Permission denied"),
    { code: "EACCES" },
  );
  const customiser = await openCustomiser(h);
  customiser.choose("Profile");
  customiser.choose("Compact");
  customiser.choose("Save & use");
  const failed = customiser.screen();
  customiser.choose("Use for this session");
  await customiser.opened;
  await h.runtime.clock.advance(0);

  expect({
    failed,
    open: customiser.open(),
    composer: customiser.editor.render(200),
    stored: h.runtime.settingsStore.stored,
  }).toStrictEqual({
    failed:
      "Footer › Customise › Couldn't save\n  Could not save /agent/session-\u001B[0m  Save error\n→ Retry\n  Use for this session\n  Back\nPreview · not saved\nenter retry · escape/ctrl+c back",
    open: false,
    composer: await composerLines('{"preset":"compact"}'),
    stored: undefined,
  });
  h.footer.shutdown();
});

it("shows the settings from disk after a conflicting draft is discarded", async () => {
  const h = harness();
  const customiser = await openCustomiser(h);
  customiser.choose("Profile");
  customiser.choose("Compact");
  h.runtime.settingsStore.stored = '{"preset":"minimal"}';
  customiser.choose("Save & use");
  customiser.choose("Review disk changes");
  customiser.choose("Discard draft & reload");
  customiser.cancel();
  await customiser.opened;
  await h.runtime.clock.advance(0);

  expect({
    open: customiser.open(),
    composer: customiser.editor.render(200),
    stored: h.runtime.settingsStore.stored,
  }).toStrictEqual({
    open: false,
    composer: await composerLines('{"preset":"minimal"}'),
    stored: '{"preset":"minimal"}',
  });
  h.footer.shutdown();
});
