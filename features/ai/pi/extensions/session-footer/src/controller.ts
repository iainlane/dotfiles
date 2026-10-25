import { Inspector, SECTIONS, type InspectorContext } from "./inspector.ts";
import { readPr, readServiceTier } from "./integrations.ts";
import { readQuota, type QuotaState } from "./quota.ts";
import { renderFooter } from "./render.ts";
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

export interface FooterView {
  render(width: number): string[];
  invalidate(): void;
  dispose(): void;
}

export interface FooterUIContext extends FooterContext, InspectorContext {
  ui: InspectorContext["ui"] & {
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

  let invalidate = noop;

  let quota: QuotaState | undefined;
  let tier: string | undefined;
  let pr: FooterSnapshot["pr"];
  const inspector = new Inspector(() =>
    session?.alive === true ? session.state : undefined,
  );
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
    inspector.dispose();
    session?.dispose();

    session = undefined;
    invalidate = noop;
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
    const section = SECTIONS.find((candidate) => candidate === args.trim());

    if (args.trim() && !section) {
      ctx.ui.notify(`Choose: ${SECTIONS.join(", ")}`, "warning");

      return;
    }

    if (session?.alive !== true) {
      ctx.ui.notify("The footer inspector is available in TUI mode.", "info");

      return;
    }

    update(ctx, true);
    session.refreshCost().catch(runtime.reportError);
    await inspector.open(ctx, section);
  };

  const start = (ctx: FooterUIContext) => {
    stop();
    connect();

    if (ctx.mode !== "tui") {
      return;
    }

    session = new FooterSession(ctx, events, requestRender, runtime);
    session.state.serviceTier = tier;
    session.state.pr = pr;

    if (matchesProvider(session.state.provider, quota)) {
      session.state.quota = quota;
    }

    const owner = session;

    ctx.ui.setFooter((tui, _theme, footerData) => {
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
          owner.state.statuses = footerData.getExtensionStatuses();

          return renderFooter(
            owner.state,
            width,
            ctx.ui.theme,
            runtime.homeDirectory,
          );
        },
        invalidate() {},
        dispose() {
          unsubscribe();
          owner.dispose();
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
