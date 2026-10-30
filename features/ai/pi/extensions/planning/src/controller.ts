import type {
  BoundaryResult,
  BeforeAgentStartEventResult,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { planningPolicy } from "./policy.ts";
import {
  attachedPlanContext,
  clearContextType,
  exitReminderType,
  implementationContext,
  planExitReminder,
  planningPrompt,
  planningReminder,
  reminderType,
} from "./prompt.ts";
import type { ReviewContext, ReviewRequest, ReviewResult } from "./review.ts";
import { PlanningSession, type SavedState } from "./session.ts";
import type { PlanRevision, PlanStore } from "./store.ts";

const clearedContextSchema = Type.Object({
  type: Type.Literal("compaction"),
  id: Type.String(),
  firstKeptEntryId: Type.String(),
  summary: Type.String(),
  details: Type.Object({
    customType: Type.Literal(clearContextType),
    token: Type.String(),
  }),
});
const compactionTypeSchema = Type.Pick(clearedContextSchema, ["type"]);

export interface PlanningContext extends ReviewContext {
  cwd: string;
  signal?: AbortSignal;
  sessionManager: {
    getSessionId(): string;
    getBranch(): readonly unknown[];
    getSessionFile(): string | undefined;
  };
  ui: ReviewContext["ui"] &
    Pick<ExtensionContext["ui"], "notify" | "setStatus" | "confirm">;
}

export interface PlanningResult {
  content: { type: "text"; text: string }[];
  details: Record<string, unknown>;
  structuredContent?: Record<string, string>;
}

export interface PlanningDependencies {
  openPlan: (sessionId: string) => PlanStore;
  recordSavedState: (state: SavedState) => void;
  configure: (sessionId: string) => (() => void)[];
  readOnlyTools: () => readonly string[];
  ensureSubagentsIdle: (signal: AbortSignal) => Promise<void>;
  startInPlan: () => boolean;
  sendUserMessage: (
    message: string,
    options?: { deliverAs?: "steer"; expandPromptTemplates?: boolean },
  ) => void;
  requestId: () => string;
  review: (ctx: ReviewContext, request: ReviewRequest) => Promise<ReviewResult>;
}

function exitMessage(
  state: PlanningSession,
): { customType: string; content: string; display: boolean } | undefined {
  if (!state.consumeExitReminder() || !state.store.exists()) {
    return undefined;
  }
  return {
    customType: exitReminderType,
    content: planExitReminder(state.store.path),
    display: false,
  };
}

export function createPlanning(dependencies: PlanningDependencies) {
  let session: PlanningSession | undefined;
  let ticket:
    | {
        token: string;
        session: PlanningSession;
        plan: PlanRevision;
        phase: "approved" | "verified" | "clearing";
        verificationSignal?: AbortSignal;
        summary?: string;
      }
    | undefined;
  let review: AbortController | undefined;
  let turnsSinceReminder = 0;

  function status(ctx: PlanningContext): void {
    ctx.ui.setStatus("planning", session?.active === true ? "Plan" : undefined);
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
    turnsSinceReminder = 0;
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
    turnsSinceReminder = 0;
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

  const command = async (args: string, ctx: PlanningContext): Promise<void> => {
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
  const submit = async (
    ctx: PlanningContext,
    signal?: AbortSignal,
    onUpdate?: (result: PlanningResult) => void,
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
    let reviewed: ReviewResult = { decision: "cancel", presentedPlan: plan };
    try {
      await dependencies.ensureSubagentsIdle(combined);
      if (!combined.aborted) {
        reviewed = await dependencies.review(ctx, {
          plan,
          signal: combined,
          read: () => state.store.read(),
          present: (presentedPlan) =>
            onUpdate?.({
              content: [{ type: "text", text: "Review the presented plan." }],
              details: { decision: "pending", presentedPlan },
            }),
        });
      }
    } catch (error) {
      if (!combined.aborted) {
        throw error;
      }
    } finally {
      review = undefined;
    }
    let decision = reviewed.decision;
    const presented = reviewed.presentedPlan;
    if (combined.aborted || session !== state || !state.active) {
      decision = "cancel";
    }
    if (
      (decision === "current" || decision === "clear") &&
      !state.store.matches(presented)
    ) {
      throw new Error(
        "The plan changed during review. Review the new revision before implementation.",
      );
    }
    if (decision === "current") {
      state.setActive(false);
      status(ctx);
    }
    if (decision === "clear") {
      const token = dependencies.requestId();
      ticket = { token, session: state, plan: presented, phase: "approved" };
      ctx.ui.notify(
        "Plan approved. Context will be cleared when this turn finishes.",
        "info",
      );
    }
    const messages: Record<ReviewResult["decision"], string> = {
      current: `Plan approved. Implement revision ${presented.revision} in this conversation.`,
      clear:
        "Plan approved. Wait for context clearing; keep this conversation in planning until the transition finishes.",
      revise:
        "The user requested revisions. Continue planning and ask for the necessary feedback.",
      cancel:
        "Plan review was cancelled. Continue planning; implementation has not been approved.",
    };
    return {
      content: [{ type: "text", text: messages[decision] }],
      details: {
        decision,
        path: presented.path,
        revision: presented.revision,
        presentedPlan: presented,
      },
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
  ): BeforeAgentStartEventResult | undefined => {
    const state = current(ctx);
    if (state.active) {
      turnsSinceReminder = 0;
      return {
        systemPrompt: `${event.systemPrompt}\n\n${planningPrompt(state.store.path)}`,
      };
    }

    const message = exitMessage(state);
    return message === undefined ? undefined : { message };
  };
  const turnEnd = (
    event: { outcome: "completed" | "aborted" | "error" },
    ctx: PlanningContext,
  ): BoundaryResult | undefined => {
    const state = current(ctx);
    if (event.outcome !== "completed") {
      return undefined;
    }
    if (!state.active) {
      const message = exitMessage(state);
      return message === undefined
        ? undefined
        : { entries: [{ type: "custom_message", ...message }] };
    }
    turnsSinceReminder++;
    if (turnsSinceReminder < 5) {
      return undefined;
    }
    turnsSinceReminder = 0;
    return {
      entries: [
        {
          type: "custom_message",
          customType: reminderType,
          content: planningReminder(state.store.path),
          display: false,
        },
      ],
    };
  };
  const verifyClear = async (ctx: PlanningContext): Promise<void> => {
    const approval = ticket;
    if (!approval || approval.phase === "clearing") {
      return;
    }
    const runSignal = ctx.signal;
    if (
      session !== approval.session ||
      !approval.session.active ||
      runSignal?.aborted !== false
    ) {
      ticket = undefined;
      return;
    }
    ticket = { ...approval, phase: "approved", verificationSignal: undefined };
    const pending = ticket;
    const signal = AbortSignal.any([approval.session.signal, runSignal]);
    try {
      await dependencies.ensureSubagentsIdle(signal);
      signal.throwIfAborted();
      if (
        ticket !== pending ||
        session !== approval.session ||
        !approval.session.store.matches(approval.plan)
      ) {
        throw new Error(
          "The plan approval expired. Review the current file again.",
        );
      }
      ticket = { ...pending, phase: "verified", verificationSignal: signal };
    } catch (error) {
      if (ticket === pending) {
        ticket = undefined;
      }
      if (!signal.aborted) {
        ctx.ui.notify(
          `Cannot clear planning context: ${String(error)}`,
          "error",
        );
      }
    }
  };
  const beforeSettle = (
    event: { outcome: "completed" | "aborted" | "error" },
    ctx: PlanningContext,
  ): BoundaryResult | undefined => {
    const approval = ticket;
    if (!approval || approval.phase === "clearing") {
      return undefined;
    }
    if (
      event.outcome !== "completed" ||
      approval.phase !== "verified" ||
      approval.verificationSignal?.aborted !== false ||
      session !== approval.session ||
      !approval.session.active
    ) {
      ticket = undefined;
      return undefined;
    }
    if (!approval.session.store.matches(approval.plan)) {
      ticket = undefined;
      ctx.ui.notify(
        "The plan approval expired. Review the current file again.",
        "error",
      );
      return undefined;
    }
    const source = ctx.sessionManager.getSessionFile() ?? approval.session.id;
    const summary = implementationContext(approval.plan, source);
    ticket = { ...approval, phase: "clearing", summary };
    return {
      entries: [
        {
          type: "compaction",
          summary,
          firstKeptEntryId: null,
          details: { customType: clearContextType, token: approval.token },
        },
      ],
    };
  };
  const settled = (event: { aborted: boolean }, ctx: PlanningContext): void => {
    const approval = ticket;
    ticket = undefined;
    if (
      event.aborted ||
      approval?.phase !== "clearing" ||
      session !== approval.session ||
      !approval.session.active
    ) {
      return;
    }
    const entry = ctx.sessionManager
      .getBranch()
      .findLast((candidate) => Check(compactionTypeSchema, candidate));
    if (
      !Check(clearedContextSchema, entry) ||
      entry.firstKeptEntryId !== entry.id ||
      entry.details.token !== approval.token ||
      entry.summary !== approval.summary ||
      !approval.session.store.matches(approval.plan)
    ) {
      ctx.ui.notify(
        "Context clearing was not confirmed for the approved revision. Review the plan again.",
        "error",
      );
      return;
    }
    approval.session.setActive(false);
    approval.session.consumeExitReminder();
    status(ctx);
    dependencies.sendUserMessage(
      `Implement the approved plan at ${approval.plan.path} (approved revision ${approval.plan.revision}).`,
      { expandPromptTemplates: false },
    );
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

  const compact = (ctx: PlanningContext): string | undefined => {
    if (!session) {
      return undefined;
    }
    const parts: string[] = [];
    if (session.active) {
      parts.push(planningReminder(session.store.path));
    } else {
      const message = exitMessage(session);
      if (message) {
        parts.push(message.content);
      }
    }
    session.setActive(session.active);
    turnsSinceReminder = 0;
    status(ctx);
    try {
      if (session.store.exists()) {
        const plan = session.store.read();
        if (plan.content.trim()) {
          parts.push(attachedPlanContext(plan));
        }
      }
    } catch (error) {
      ctx.ui.notify(`Cannot restore plan context: ${String(error)}`, "warning");
    }
    return parts.length > 0 ? parts.join("\n\n") : undefined;
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
    submit,
    toolCall,
    prompt,
    turnEnd,
    verifyClear,
    beforeSettle,
    settled,
    start,
    restore,
    compact,
    shutdown,
  };
}
