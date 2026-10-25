import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { createPiPrClient } from "pi-prs/api";
import { Inspector, SECTIONS } from "./inspector.ts";
import { readPr, readServiceTier } from "./integrations.ts";
import { readQuota, type QuotaState } from "./quota.ts";
import { renderFooter } from "./render.ts";
import { FooterSession, reportRefreshError } from "./session.ts";
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

export default function sessionFooter(pi: ExtensionAPI): void {
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

    session.state.now = Date.now();

    invalidate();
  };

  const update = (ctx: ExtensionContext, force = false) => {
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
    session?.refreshAgents().catch(reportRefreshError);
  };

  const connect = () => {
    if (stops.length > 0) {
      return;
    }

    for (const channel of ["sub-core:ready", "sub-core:update-current"]) {
      stops.push(pi.events.on(channel, updateQuota));
    }

    stops.push(
      pi.events.on("pi-fancy-footer:widget", (raw) => {
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
      createPiPrClient(pi).onState((raw) => {
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
      pi.events.on("pilens:diagnostics", (raw) => {
        session?.state.diagnostics.receive(raw);
        requestRender();
      }),
      pi.events.on("pilens:files:touched", (raw) => {
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
      stops.push(pi.events.on(channel, refreshAgents));
    }
  };

  connect();

  pi.registerCommand("footer", {
    description:
      "Inspect footer measurements, workflow state and integration details",
    handler: async (args, ctx) => {
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
      session.refreshCost().catch(reportRefreshError);
      await inspector.open(ctx, section);
    },
  });

  pi.on("session_start", (_event, ctx) => {
    stop();
    connect();

    if (ctx.mode !== "tui") {
      return;
    }

    session = new FooterSession(ctx, pi.events, requestRender);
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
        owner.refreshGit().catch(reportRefreshError);
      });

      return {
        render(width) {
          owner.state.statuses = footerData.getExtensionStatuses();

          return renderFooter(owner.state, width, ctx.ui.theme);
        },
        invalidate() {},
        dispose() {
          unsubscribe();
          owner.dispose();
        },
      };
    });
    pi.events.emit("pi-fancy-footer:ready", { protocol: 1 });
    pi.events.emit("sub-core:request", {
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
  });

  pi.on("session_shutdown", () => {
    stop();

    quota = undefined;
    tier = undefined;
    pr = undefined;

    for (const unsubscribe of stops.splice(0)) {
      unsubscribe();
    }
  });

  pi.on("session_tree", (_event, ctx) => {
    update(ctx, true);
  });

  pi.on("message_end", (event, ctx) => {
    update(ctx, true);

    if (
      session &&
      event.message.role === "assistant" &&
      event.message.stopReason === "error"
    ) {
      session.state.activity.outcome = "failed";
    }
  });

  pi.on("model_select", (_event, ctx) => {
    update(ctx);
  });

  pi.on("thinking_level_select", (_event, ctx) => {
    update(ctx);
  });

  pi.on("agent_start", (_event, ctx) => {
    update(ctx);
    session?.activity("start");
  });

  pi.on("agent_settled", (event, ctx) => {
    update(ctx, true);
    session?.activity("settled", event.aborted ? "cancelled" : undefined);
    session?.refreshGit().catch(reportRefreshError);
    session?.refreshCost().catch(reportRefreshError);
  });

  pi.on("message_update", () => {
    session?.activity("content");
  });

  pi.on("ui_prompt_start", () => {
    session?.activity("wait");
  });

  pi.on("ui_prompt_end", () => {
    session?.activity("resume");
  });

  pi.on("session_before_compact", () => {
    session?.activity("compact");
  });

  pi.on("session_compact", (_event, ctx) => {
    session?.activity("compacted");
    update(ctx, true);
  });

  pi.on("session_compact_failed", () => {
    session?.activity("compacted");
  });

  pi.on("tool_execution_start", (event) => {
    session?.tool(event.toolCallId, event.toolName);
  });

  pi.on("tool_execution_end", (event) => {
    session?.tool(event.toolCallId);
    session?.refreshGit().catch(reportRefreshError);
  });
}
