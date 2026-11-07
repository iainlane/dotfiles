import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { ComposerEditor } from "./composer.ts";
import { Inspector, type InspectorContext } from "./inspector.ts";
import { parseFooterCommand } from "./commands.ts";
import { loadSettings, resolveSettings } from "./settings.ts";
import { readPr, readServiceTier } from "./integrations.ts";
import { readQuota, type QuotaState } from "./quota.ts";
import {
  fitFooterRow,
  layoutFooter,
  renderFooter,
  type RenderFrame,
} from "./render.ts";
import { FooterSession, type FooterContext } from "./session.ts";
import type { FooterRuntime } from "./runtime.ts";
import type { FooterBus } from "./rpc.ts";
import type { FooterSnapshot } from "./state.ts";

function matchesProvider(
  provider: string,
  quota: QuotaState | undefined,
): boolean {
  return Boolean(
    quota &&
    (provider === quota.provider ||
      (provider === "openai-codex" && quota.provider === "codex")),
  );
}

const noop = () => {};
const emptyStatuses = (): ReadonlyMap<string, string> => new Map();

type EditorUI = Pick<
  ExtensionUIContext,
  "getEditorComponent" | "setEditorComponent"
>;
type EditorFactory = NonNullable<ReturnType<EditorUI["getEditorComponent"]>>;

interface ComposerOwnership {
  ui: EditorUI;
  factory: EditorFactory;
  previous: EditorFactory | undefined;
}

export interface FooterView {
  render(width: number): string[];
  invalidate(): void;
  dispose(): void;
}

export interface FooterUIContext extends FooterContext, InspectorContext {
  ui: InspectorContext["ui"] &
    EditorUI & {
      theme: NonNullable<Parameters<typeof renderFooter>[2]>;
      setFooter(
        factory: (
          tui: { requestRender(): void },
          theme: unknown,
          data: {
            onBranchChange(callback: () => void): () => void;
            getExtensionStatuses(): ReadonlyMap<string, string>;
          },
        ) => FooterView,
      ): void;
    };
}

export interface FooterDependencies {
  events: FooterBus;
  runtime: FooterRuntime;
  subscribePr: (callback: (value: unknown) => void) => () => void;
}

export function createFooter({
  events,
  runtime,
  subscribePr,
}: FooterDependencies) {
  let session: FooterSession | undefined;
  let composer: ComposerOwnership | undefined;

  const ownsComposer = () =>
    composer !== undefined &&
    composer.ui.getEditorComponent() === composer.factory;

  let invalidate = noop;

  let quota: QuotaState | undefined;
  let tier: string | undefined;
  let pr: FooterSnapshot["pr"];
  let settings = loadSettings((): undefined => {}, runtime.settingsPath);
  let lastFrame: RenderFrame | undefined;
  let nativeStatuses = emptyStatuses;
  const snapshot = (): FooterSnapshot | undefined => {
    if (session?.alive !== true) {
      return undefined;
    }
    session.state.statuses = new Map(nativeStatuses());
    return session.state;
  };
  const inspector = new Inspector(snapshot, {
    frame: () => lastFrame,
    settings: () => settings,
    preview: (preset) => {
      const state = snapshot();
      return state && lastFrame
        ? layoutFooter(
            state,
            { top: lastFrame.top.width, bottom: lastFrame.bottom.width },
            {
              settings: {
                ...resolveSettings({ preset }),
                symbols: settings.symbols,
              },
              home: runtime.homeDirectory,
              mode: "preview",
            },
          )
        : undefined;
    },
    enterUsage: () => {
      session?.refreshCost().catch(runtime.reportError);
    },
  });
  const stops: (() => void)[] = [];

  const requestRender = () => {
    if (session?.alive !== true) {
      return;
    }

    session.state.now = runtime.clock.now();

    invalidate();
  };

  const update = (ctx: FooterUIContext, force = false) => {
    if (session?.alive !== true) {
      return;
    }

    session.sync(ctx, force);

    if (matchesProvider(session.state.provider, quota)) {
      session.state.quota = quota;
    }

    session.state.serviceTier = tier;

    requestRender();
  };

  const stop = () => {
    const mounted = composer;
    composer = undefined;

    if (
      mounted !== undefined &&
      mounted.ui.getEditorComponent() === mounted.factory
    ) {
      mounted.ui.setEditorComponent(mounted.previous);
    }

    inspector.dispose();
    session?.dispose();

    session = undefined;
    invalidate = noop;
    nativeStatuses = emptyStatuses;
    lastFrame = undefined;
  };

  const updateQuota = (raw: unknown) => {
    quota = readQuota(raw, quota);

    if (session?.alive !== true) {
      return;
    }

    session.state.quota = matchesProvider(session.state.provider, quota)
      ? quota
      : undefined;

    requestRender();
  };

  const refreshAgents = () => {
    session?.refreshAgents().catch(runtime.reportError);
  };

  const connect = () => {
    if (stops.length > 0) {
      return;
    }

    for (const channel of ["sub-core:ready", "sub-core:update-current"]) {
      stops.push(events.on(channel, updateQuota));
    }

    stops.push(
      events.on("dotfiles:status:v1", (raw) => {
        if (session?.receiveStatus(raw) === true) {
          requestRender();
        }
      }),
      events.on("pi-fancy-footer:widget", (raw) => {
        const next = readServiceTier(raw);

        if (next === undefined) {
          return;
        }

        tier = next || undefined;

        if (session?.alive === true) {
          session.state.serviceTier = tier;
        }

        requestRender();
      }),
      subscribePr((raw) => {
        const next = readPr(raw);

        pr = next ?? (pr && { ...pr, health: "error" });

        if (
          session?.alive !== true ||
          (session.state.git && pr?.branch !== session.state.git.branch)
        ) {
          return;
        }

        session.state.pr = pr;

        requestRender();
      }),
      events.on("pilens:diagnostics", (raw) => {
        session?.state.diagnostics.receive(raw);
        requestRender();
      }),
      events.on("pilens:files:touched", (raw) => {
        session?.state.diagnostics.touch(raw);
        requestRender();
      }),
    );

    for (const channel of [
      "subagents:rpc:v1:ready",
      "subagent:async-started",
      "subagent:async-complete",
      "subagent:child-status",
    ]) {
      stops.push(events.on(channel, refreshAgents));
    }
  };

  connect();

  const inspect = async (args: string, ctx: FooterUIContext) => {
    const route = parseFooterCommand(args);

    if ("error" in route) {
      ctx.ui.notify(route.error, "warning");

      return;
    }

    if (session?.alive !== true) {
      ctx.ui.notify("The footer inspector is available in TUI mode.", "info");

      return;
    }

    update(ctx, true);
    await inspector.open(ctx, route);
  };

  const start = (ctx: FooterUIContext) => {
    stop();
    connect();

    if (ctx.mode !== "tui") {
      return;
    }

    settings = loadSettings(() => runtime.readSettings(), runtime.settingsPath);
    if (settings.diagnostic !== undefined) {
      ctx.ui.notify(settings.diagnostic, "warning");
    }
    session = new FooterSession(ctx, events, requestRender, runtime);
    session.state.serviceTier = tier;
    session.state.pr = pr;

    if (matchesProvider(session.state.provider, quota)) {
      session.state.quota = quota;
    }

    const owner = session;
    if (owner.state.sessionId !== undefined) {
      events.emit("dotfiles:status:request:v1", {
        version: 1,
        sessionId: owner.state.sessionId,
      });
    }

    ctx.ui.setFooter((tui, _theme, footerData) => {
      nativeStatuses = () => footerData.getExtensionStatuses();
      invalidate = () => {
        if (owner.alive) {
          tui.requestRender();
        }
      };

      const unsubscribe = footerData.onBranchChange(() => {
        owner.refreshGit().catch(runtime.reportError);
      });

      return {
        render(width) {
          if (ownsComposer() || !owner.alive) {
            return [];
          }
          owner.state.statuses = new Map(nativeStatuses());
          owner.state.now = runtime.clock.now();
          const frame = layoutFooter(
            owner.state,
            { top: width, bottom: width },
            {
              settings,
              theme: ctx.ui.theme,
              home: runtime.homeDirectory,
              mode: "fallback",
            },
          );
          lastFrame = frame;
          return [frame.top.text, frame.bottom.text].filter(
            (row) => row.trim() !== "",
          );
        },
        invalidate() {},
        dispose() {
          unsubscribe();
        },
      };
    });
    events.emit("pi-fancy-footer:ready", { protocol: 1 });
    events.emit("sub-core:request", {
      type: "current",
      reply: (raw: unknown) => {
        if (!owner.alive) {
          return;
        }

        quota = readQuota(raw, quota);
        owner.state.quota = matchesProvider(owner.state.provider, quota)
          ? quota
          : undefined;

        requestRender();
      },
    });
  };

  const mountComposer = (ctx: FooterUIContext) => {
    if (
      ctx.mode !== "tui" ||
      session?.alive !== true ||
      composer !== undefined
    ) {
      return;
    }

    const owner = session;
    const factory: EditorFactory = (tui, theme, keybindings) => {
      let pending: RenderFrame | undefined;
      const render = (width: number, border: "top" | "bottom") => {
        if (!owner.alive) {
          return "";
        }
        if (border === "top") {
          owner.state.now = runtime.clock.now();
          owner.state.statuses = new Map(nativeStatuses());
          pending = layoutFooter(
            owner.state,
            { top: width, bottom: 0 },
            {
              settings,
              theme: ctx.ui.theme,
              home: runtime.homeDirectory,
              mode: "composer",
            },
          );
          return pending.top.text;
        }
        if (!pending) {
          return "";
        }
        const bottom = fitFooterRow(pending, settings, {
          placement: "bottom",
          width,
          theme: ctx.ui.theme,
        });
        pending = {
          ...pending,
          bottom: bottom.row,
          decisions: [
            ...pending.decisions.filter((decision) =>
              decision.region.startsWith("top-"),
            ),
            ...bottom.decisions,
          ],
        };
        return pending.bottom.text;
      };
      return new ComposerEditor(tui, theme, keybindings, {
        top: (width) => render(width, "top"),
        bottom: (width) => render(width, "bottom"),
        completed: () => {
          if (owner.alive && ownsComposer() && pending) {
            lastFrame = pending;
          }
        },
      });
    };

    composer = { ui: ctx.ui, factory, previous: ctx.ui.getEditorComponent() };
    ctx.ui.setEditorComponent(factory);
    requestRender();
  };

  const shutdown = () => {
    stop();

    quota = undefined;
    tier = undefined;
    pr = undefined;

    for (const unsubscribe of stops.splice(0)) {
      unsubscribe();
    }
  };

  const selectBranch = (ctx: FooterUIContext) => {
    update(ctx, true);
  };

  const endMessage = (ctx: FooterUIContext, failed: boolean) => {
    if (session && failed) {
      session.state.activity.outcome = "failed";
    }

    update(ctx, true);
  };

  const selectModel = (ctx: FooterUIContext) => {
    update(ctx);
  };

  const selectThinking = (ctx: FooterUIContext) => {
    update(ctx);
  };

  const startAgent = (ctx: FooterUIContext) => {
    update(ctx);
    session?.activity("start");
  };

  const settleAgent = (ctx: FooterUIContext, aborted: boolean) => {
    update(ctx, true);
    session?.activity("settled", aborted ? "cancelled" : undefined);
    session?.refreshGit().catch(runtime.reportError);
    session?.refreshCost().catch(runtime.reportError);
  };

  const updateMessage = () => {
    session?.activity("content");
  };

  const startPrompt = () => {
    session?.activity("wait");
  };

  const endPrompt = () => {
    session?.activity("resume");
  };

  const startCompaction = () => {
    session?.activity("compact");
  };

  const finishCompaction = (ctx: FooterUIContext) => {
    session?.activity("compacted");
    update(ctx, true);
  };

  const failCompaction = () => {
    session?.activity("compacted");
  };

  const startTool = (id: string, name: string) => {
    session?.tool(id, name);
  };

  const endTool = (id: string) => {
    session?.tool(id);
    session?.refreshGit().catch(runtime.reportError);
  };
  return {
    inspect,
    start,
    mountComposer,
    shutdown,
    selectBranch,
    endMessage,
    selectModel,
    selectThinking,
    startAgent,
    settleAgent,
    updateMessage,
    startPrompt,
    endPrompt,
    startCompaction,
    finishCompaction,
    failCompaction,
    startTool,
    endTool,
  };
}
