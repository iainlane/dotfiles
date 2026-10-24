import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { research, type ResearchTransport } from "./delegation.ts";
import { planningPolicy } from "./policy.ts";
import { planningPrompt } from "./prompt.ts";
import type { ReviewContext, ReviewDecision } from "./review.ts";
import { PlanningSession, type SavedState } from "./session.ts";
import type { PlanRevision, PlanStore } from "./store.ts";

export interface PlanningContext extends ReviewContext {
  cwd: string;
  signal?: AbortSignal;
  thinkingLevel?: ExtensionContext["thinkingLevel"];
  sessionManager: {
    getSessionId(): string;
    getBranch(): readonly unknown[];
    getSessionFile(): string | undefined;
  };
  ui: ReviewContext["ui"] &
    Pick<ExtensionContext["ui"], "notify" | "setStatus" | "confirm">;
}

export interface PlanningCommandContext extends PlanningContext {
  handoff: (request: {
    parentSession?: string;
    message: string;
  }) => Promise<void>;
}

export interface PlanningResult {
  content: { type: "text"; text: string }[];
  details: Record<string, unknown>;
  structuredContent?: Record<string, string>;
}

export interface ResearchParameters {
  role: "explore" | "plan";
  brief: string;
  model?: string;
  thinking?: ExtensionContext["thinkingLevel"];
}

export interface PlanningDependencies {
  openPlan: (sessionId: string) => PlanStore;
  recordSavedState: (state: SavedState) => void;
  configure: (sessionId: string) => (() => void)[];
  readOnlyTools: () => readonly string[];
  startInPlan: () => boolean;
  sendUserMessage: (
    message: string,
    options?: { deliverAs?: "steer"; expandPromptTemplates?: boolean },
  ) => void;
  requestId: () => string;
  transport: ResearchTransport;
  review: (
    ctx: ReviewContext,
    plan: PlanRevision,
    signal: AbortSignal,
  ) => Promise<ReviewDecision>;
}

export function createPlanning(dependencies: PlanningDependencies) {
  let session: PlanningSession | undefined;
  let ticket:
    | {
        token: string;
        session: PlanningSession;
        plan: PlanRevision;
        phase: "approved" | "queued" | "pending" | "failed";
      }
    | undefined;
  let review: AbortController | undefined;
  let researching = 0;

  function status(ctx: PlanningContext): void {
    ctx.ui.setStatus(
      "planning",
      session?.active === true
        ? `Plan${researching ? ` · ${researching} researching` : ""}`
        : undefined,
    );
  }

  function configure(state: PlanningSession): void {
    if (state.disposers.length > 0) {
      return;
    }
    state.disposers.push(...dependencies.configure(state.id));
  }

  function current(ctx: PlanningContext): PlanningSession {
    if (!session || session.id !== ctx.sessionManager.getSessionId()) {
      restore(ctx);
    }
    if (!session) {
      throw new Error("The planning session is unavailable.");
    }
    return session;
  }

  function enter(ctx: PlanningContext): PlanningSession {
    ticket = undefined;
    const state = current(ctx);
    configure(state);
    state.enter();
    status(ctx);
    return state;
  }

  function restore(ctx: PlanningContext): void {
    const replacement = new PlanningSession(
      {
        id: ctx.sessionManager.getSessionId(),
        branch: ctx.sessionManager.getBranch(),
      },
      dependencies.openPlan,
      dependencies.recordSavedState,
    );
    review?.abort();
    ticket = undefined;
    session?.dispose();
    researching = 0;
    session = replacement;
    if (session.active) {
      try {
        configure(session);
      } catch (error) {
        ctx.ui.notify(
          `Planning research is unavailable: ${String(error)}`,
          "error",
        );
      }
    }
    status(ctx);
  }

  async function fresh(
    args: string,
    ctx: PlanningCommandContext,
  ): Promise<void> {
    const approval = ticket;
    if (
      !approval ||
      approval.phase === "pending" ||
      args !== approval.token ||
      session !== approval.session ||
      !approval.session.active ||
      !approval.session.store.matches(approval.plan)
    ) {
      ctx.ui.notify(
        "The plan approval expired. Review the current file again.",
        "warning",
      );
      return;
    }
    const source =
      ctx.sessionManager.getSessionFile() ?? ctx.sessionManager.getSessionId();
    approval.phase = "pending";
    try {
      await ctx.handoff({
        parentSession: ctx.sessionManager.getSessionFile(),
        message: `Implement this approved plan.\n\nSource conversation: ${source}\nPlan: ${approval.plan.path}\nApproved revision: ${approval.plan.revision}\n\n${approval.plan.content}`,
      });
      if (ticket === approval) {
        ticket = undefined;
      }
    } catch (error) {
      if (ticket === approval) {
        approval.phase = "failed";
      }
      throw error;
    }
  }

  const command = async (
    args: string,
    ctx: PlanningCommandContext,
  ): Promise<void> => {
    if (args.startsWith("handoff ")) {
      await fresh(args.slice(8), ctx);
      return;
    }
    const state = current(ctx);
    if (args.trim() === "review") {
      ticket = undefined;
      if (!state.active) {
        ctx.ui.notify("Enter Plan mode first.", "info");
        return;
      }
      dependencies.sendUserMessage(
        "Review the active plan, resolve any remaining questions, and call submit_plan.",
        { deliverAs: "steer" },
      );
      return;
    }
    if (!args.trim() && state.active) {
      ticket = undefined;
      review?.abort();
      state.setActive(false);
      status(ctx);
      ctx.ui.notify(
        `Plan mode ended. Draft preserved at ${state.store.path}`,
        "info",
      );
      return;
    }
    enter(ctx);
    if (args.trim()) {
      dependencies.sendUserMessage(`Plan this task: ${args.trim()}`, {
        deliverAs: "steer",
      });
    } else {
      ctx.ui.notify(`Plan mode enabled. Draft: ${state.store.path}`, "info");
    }
  };
  const toggle = (ctx: PlanningContext): void => {
    const state = current(ctx);
    if (state.active) {
      ticket = undefined;
      review?.abort();
      state.setActive(false);
      status(ctx);
    } else {
      enter(ctx);
    }
  };

  const enterTool = async (
    ctx: PlanningContext,
    signal?: AbortSignal,
  ): Promise<PlanningResult> => {
    signal?.throwIfAborted();
    const state = enter(ctx);
    return {
      content: [{ type: "text", text: planningPrompt(state.store.path) }],
      details: { path: state.store.path },
      structuredContent: {
        path: state.store.path,
        instructions: planningPrompt(state.store.path),
      },
    };
  };
  const investigate = async (
    params: ResearchParameters,
    ctx: PlanningContext,
    signal?: AbortSignal,
    onUpdate?: (result: PlanningResult) => void,
  ): Promise<PlanningResult> => {
    const state = current(ctx);
    if (!state.active) {
      throw new Error("Enter Plan mode before delegating planning research.");
    }
    configure(state);
    if (researching >= 3) {
      throw new Error(
        "Three investigations are already running. Wait for a result before starting another.",
      );
    }
    const combined = signal
      ? AbortSignal.any([state.signal, signal])
      : state.signal;
    researching++;
    status(ctx);
    try {
      const result = await research(
        dependencies.transport,
        {
          ownerRunId: state.id,
          agent: `planning-${params.role}`,
          task: params.brief,
          cwd: ctx.cwd,
          model: params.model,
          thinking: params.thinking ?? ctx.thinkingLevel,
          timeoutMs: 300_000,
          skill: false,
          artifacts: false,
        },
        combined,
        (update) => {
          if (session !== state || combined.aborted) {
            return;
          }
          onUpdate?.({
            content: [
              {
                type: "text",
                text:
                  update.recentOutput ?? update.currentTool ?? "Researching…",
              },
            ],
            details: { role: params.role },
          });
        },
      );
      combined.throwIfAborted();
      if (session !== state || !state.active) {
        throw new Error("The planning investigation expired.");
      }
      if (result.status !== "completed" || result.result?.kind !== "text") {
        throw new Error(
          `Planning research ${result.status}: ${result.error ?? "no report returned"}`,
        );
      }
      return {
        content: [{ type: "text", text: result.result.text }],
        details: {
          role: params.role,
          runId: result.runId,
          usage: result.usage,
        },
      };
    } finally {
      if (session === state) {
        researching--;
        status(ctx);
      }
    }
  };
  const submit = async (
    ctx: PlanningContext,
    signal?: AbortSignal,
  ): Promise<PlanningResult> => {
    const state = current(ctx);
    if (!state.active) {
      throw new Error("Plan mode is not active.");
    }
    if (review) {
      throw new Error("A plan review is already open.");
    }
    ticket = undefined;
    const plan = state.store.read();
    if (
      !plan.content.trim() ||
      plan.content ===
        "# Implementation plan\n\nDraft the recommended approach here.\n"
    ) {
      throw new Error(
        "Write the implementation plan before requesting approval.",
      );
    }
    review = new AbortController();
    const combined = AbortSignal.any([
      state.signal,
      review.signal,
      ...(signal ? [signal] : []),
    ]);
    let decision;
    try {
      decision = await dependencies.review(ctx, plan, combined);
    } finally {
      review = undefined;
    }
    if (combined.aborted || session !== state || !state.active) {
      decision = "cancel";
    }
    if (
      (decision === "current" || decision === "fresh") &&
      !state.store.matches(plan)
    ) {
      throw new Error(
        "The plan changed during review. Review the new revision before implementation.",
      );
    }
    if (decision === "current") {
      state.setActive(false);
      status(ctx);
    }
    if (decision === "fresh") {
      const token = dependencies.requestId();
      ticket = { token, session: state, plan, phase: "approved" };
      ctx.ui.notify(
        "Plan approved. A fresh conversation will start when this turn finishes.",
        "info",
      );
    }
    return {
      content: [
        {
          type: "text",
          text:
            decision === "current"
              ? `Plan approved. Implement revision ${plan.revision} in this conversation.`
              : decision === "fresh"
                ? "Plan approved for a fresh conversation. Wait for the handoff; keep this conversation in planning."
                : decision === "revise"
                  ? "The user requested revisions. Continue planning and ask for the necessary feedback."
                  : "Plan review was cancelled. Continue planning; implementation has not been approved.",
        },
      ],
      details: { decision, path: plan.path, revision: plan.revision },
    };
  };

  const toolCall = async (
    event: { toolName: string; input: Record<string, unknown> },
    ctx: PlanningContext,
  ): Promise<{ block: true; reason: string } | undefined> => {
    const state = current(ctx);
    if (!state.active) {
      return undefined;
    }
    let readOnlyTools: readonly string[];
    try {
      readOnlyTools = dependencies.readOnlyTools();
    } catch (error) {
      return {
        block: true,
        reason: `Planning settings are unavailable: ${String(error)}`,
      };
    }
    return planningPolicy(
      event,
      ctx,
      state.store,
      readOnlyTools,
      AbortSignal.any([state.signal, ...(ctx.signal ? [ctx.signal] : [])]),
    );
  };
  const prompt = (
    event: { systemPrompt: string },
    ctx: PlanningContext,
  ): { systemPrompt: string } | undefined => {
    const state = current(ctx);
    if (state.active) {
      return {
        systemPrompt: `${event.systemPrompt}\n\n${planningPrompt(state.store.path)}`,
      };
    }

    return undefined;
  };
  const settled = (event: { aborted: boolean }): void => {
    if (event.aborted) {
      if (ticket?.phase !== "failed") {
        ticket = undefined;
      }
      return;
    }
    if (ticket?.phase === "approved") {
      ticket.phase = "queued";
      dependencies.sendUserMessage(`/plan handoff ${ticket.token}`, {
        expandPromptTemplates: true,
      });
    }
  };
  const start = (event: { reason: string }, ctx: PlanningContext): void => {
    restore(ctx);
    if (
      event.reason === "startup" &&
      dependencies.startInPlan() &&
      session?.active !== true
    ) {
      enter(ctx);
    }
  };

  const compact = (ctx: PlanningContext): void => {
    if (session) {
      session.setActive(session.active);
      status(ctx);
    }
  };
  const shutdown = (): void => {
    review?.abort();
    session?.dispose();
    ticket = undefined;
  };

  return {
    command,
    toggle,
    enterTool,
    investigate,
    submit,
    toolCall,
    prompt,
    settled,
    start,
    restore,
    compact,
    shutdown,
  };
}
