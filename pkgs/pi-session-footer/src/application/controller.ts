import type {
  ExtensionUIContext,
  KeybindingsManager,
} from "@earendil-works/pi-coding-agent";
import { ComposerEditor, type ComposerGeometry } from "#footer/ui/composer.ts";
import { Customiser } from "#footer/ui/customiser/customiser.ts";
import type { SettingsSnapshot } from "#footer/configuration/settings-store.ts";
import {
  Inspector,
  type InspectorContext,
} from "#footer/ui/inspection/inspector.ts";
import { parseFooterCommand } from "./commands.ts";
import {
  loadSettings,
  resolveSettings,
  presentationDocument,
  type PresentationDocument,
  type ResolvedSettings,
} from "#footer/configuration/settings.ts";
import { readPr, readServiceTier } from "#footer/integrations/integrations.ts";
import { readQuota, type QuotaState } from "#footer/domain/quota.ts";
import {
  observeFooter,
  renderFooter,
  type FooterPresentation,
  type RenderFrame,
} from "#footer/rendering/render.ts";
import {
  FooterLayoutCache,
  type FooterLayout,
} from "#footer/rendering/layout-cache.ts";
import { FooterSession, type FooterContext } from "./session.ts";
import type { FooterRuntime } from "./runtime.ts";
import type { FooterBus } from "#footer/integrations/rpc.ts";
import type { FooterSnapshot } from "#footer/domain/state.ts";

function matchesProvider(
  provider: string,
  quota: QuotaState | undefined,
): boolean {
  return Boolean(
    quota &&
    (provider === quota.provider ||
      ((provider === "openai" || provider === "openai-codex") &&
        quota.provider === "codex")),
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
    EditorUI &
    Pick<ExtensionUIContext, "setWidget"> & {
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
  let inspection = 0;
  let composer: ComposerOwnership | undefined;

  const ownsComposer = () =>
    composer !== undefined &&
    composer.ui.getEditorComponent() === composer.factory;

  let redraw = noop;

  let quota: QuotaState | undefined;
  let tier: string | undefined;
  let pr: FooterSnapshot["pr"];
  let settings = loadSettings((): undefined => {}, runtime.settingsPath);
  let lastFrame: RenderFrame | undefined;
  let stored: SettingsSnapshot | undefined;
  let applied: PresentationDocument | undefined;
  let preview: PresentationDocument | undefined;
  let geometry: ComposerGeometry | undefined;
  let nativeKeys: KeybindingsManager | undefined;
  let fallbackLines: string[] = [];
  let resolved:
    | { document: PresentationDocument; settings: ResolvedSettings }
    | undefined;
  const presentation = () => {
    const document = preview ?? applied;
    if (document === undefined) {
      return settings;
    }
    if (resolved?.document !== document) {
      resolved = { document, settings: resolveSettings(document) };
    }
    return resolved.settings;
  };
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
    enterUsage: () => {
      void session?.refreshCost();
    },
  });
  const stops: (() => void)[] = [];
  let revision = 0;

  const requestRender = () => {
    if (session?.alive !== true) {
      return;
    }

    revision++;
    session.state.now = runtime.clock.now();

    redraw();
  };

  const layoutCache = (
    owner: FooterSession,
    ctx: FooterUIContext,
    mode: "composer" | "fallback",
  ) =>
    new FooterLayoutCache({
      revision: () => revision,
      statuses: () => nativeStatuses(),
      observe: (statuses) => {
        owner.state.statuses = new Map(statuses);
        owner.state.now = runtime.clock.now();
        const current: FooterPresentation = {
          settings: presentation(),
          theme: ctx.ui.theme,
          home: runtime.homeDirectory,
          mode: preview === undefined ? mode : "preview",
        };
        return {
          observation: observeFooter(owner.state, current),
          presentation: current,
        };
      },
    });

  const customiser = new Customiser({
    store: runtime.settingsStore,
    homeDirectory: runtime.homeDirectory,
    keys: () => nativeKeys,
    previewLines: () =>
      ownsComposer() ? (geometry?.lines ?? []) : fallbackLines,
    composerHeight: () => geometry?.height ?? 3,
    presentationMode: () => (ownsComposer() ? "composer" : "fallback"),
    sessionApplied: () => applied !== undefined,
    sourceIds: () => {
      const state = snapshot();
      return state === undefined
        ? []
        : [
            ...new Set([
              ...state.statuses.keys(),
              ...state.cooperativeStatuses.keys(),
            ]),
          ];
    },
    present: (document) => {
      preview = document;
      requestRender();
    },
    saved: (source) => {
      stored = source;
      settings = source.loaded;
      applied = undefined;
      requestRender();
    },
    reloaded: (source) => {
      stored = source;
      settings = source.loaded;
      applied = undefined;
      requestRender();
    },
    applied: (document) => {
      applied = document;
      requestRender();
    },
  });

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
    inspection++;
    customiser.dispose();
    preview = undefined;
    applied = undefined;
    stored = undefined;
    geometry = undefined;
    nativeKeys = undefined;
    fallbackLines = [];
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
    redraw = noop;
    nativeStatuses = emptyStatuses;
    lastFrame = undefined;
    resolved = undefined;
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
    void session?.refreshAgents();
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

        if (session?.receivePr(pr) === true) {
          requestRender();
        }
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

    const interaction = ++inspection;
    const owner = session;
    customiser.dispose();
    inspector.dispose();
    update(ctx, true);
    if (route.view === "config" && stored !== undefined) {
      await customiser.open(
        ctx,
        stored,
        applied ?? presentationDocument(settings.document),
      );
      return;
    }
    const next = await inspector.open(ctx, route);
    if (
      next === "customise" &&
      interaction === inspection &&
      session === owner &&
      owner.alive &&
      stored !== undefined
    ) {
      await customiser.open(
        ctx,
        stored,
        applied ?? presentationDocument(settings.document),
      );
    }
  };

  const start = (ctx: FooterUIContext) => {
    stop();
    connect();

    if (ctx.mode !== "tui") {
      return;
    }

    stored = runtime.settingsStore.load();
    settings = stored.loaded;
    if (settings.diagnostic !== undefined) {
      ctx.ui.notify(settings.diagnostic, "warning");
    }
    session = new FooterSession(ctx, events, requestRender, runtime);
    session.state.serviceTier = tier;
    session.receivePr(pr);

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
      const layout = layoutCache(owner, ctx, "fallback");
      nativeStatuses = () => footerData.getExtensionStatuses();
      redraw = () => {
        if (owner.alive) {
          tui.requestRender();
        }
      };

      const unsubscribe = footerData.onBranchChange(() => {
        void owner.refreshGit();
      });

      return {
        render(width) {
          if (ownsComposer() || !owner.alive) {
            fallbackLines = [];
            return [];
          }
          const frame = layout.current().frame({ top: width, bottom: width });
          if (frame.mode !== "preview") {
            lastFrame = frame;
          }
          fallbackLines = [frame.top.text, frame.bottom.text].filter(
            (row) => row.trim() !== "",
          );
          return fallbackLines;
        },
        invalidate() {
          layout.invalidate();
        },
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
      nativeKeys = keybindings;
      const cache = layoutCache(owner, ctx, "composer");
      const widths = { top: 0, bottom: 0 };
      let layout: FooterLayout | undefined;
      return new ComposerEditor(tui, theme, keybindings, {
        top: (width) => {
          if (!owner.alive) {
            return "";
          }
          layout = cache.current();
          widths.top = width;
          widths.bottom = 0;
          return layout.row("top", width).row.text;
        },
        bottom: (width) => {
          if (!owner.alive || !layout) {
            return "";
          }
          widths.bottom = width;
          return layout.row("bottom", width).row.text;
        },
        completed: (completed) => {
          if (!owner.alive || !ownsComposer() || !layout) {
            return;
          }
          const changed = geometry?.height !== completed.height;
          geometry = completed;
          if (layout.presentation.mode !== "preview") {
            lastFrame = layout.frame(widths);
          }
          if (changed) {
            redraw();
          }
        },
        invalidate: () => {
          cache.invalidate();
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
    void session?.refreshGit();
    void session?.refreshCost();
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
    void session?.refreshGit();
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
