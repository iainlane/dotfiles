import type {
  BoundaryResult,
  BeforeAgentStartEventResult,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import type {
  ImageContent,
  JsonObject,
  JsonValue,
  TextContent,
} from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { planningPolicy } from "./policy.ts";
import type { PlanEditor } from "./editor.ts";
import {
  attachedPlanContext,
  reviewedPlanContext,
  reviewFeedbackContext,
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
import {
  validateFeedbackText,
  validateImageInput,
  validatePlanDocument,
} from "./validation.ts";
import type { EnterPlanOutput, SubmitPlanOutput } from "./contracts.ts";
import type { PlanningOutcome } from "./outcomes.ts";
import { displayText } from "./presentation.ts";

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

type ReviewedPlanDetails = {
  formatVersion: 1;
  decision: ReviewResult["decision"];
  path: string;
  revision: string;
  presentedPlan: PlanRevision;
  reviewSummary: string;
  feedback?: string;
};

export interface PlanningResult<TStructured extends JsonValue = JsonObject> {
  content: (TextContent | ImageContent)[];
  details: Record<string, unknown>;
  structuredContent?: TStructured;
}

export interface PlanningDependencies {
  openPlan: (sessionId: string) => PlanStore;
  presentPlan: (plan: PlanRevision) => void;
  recordSavedState: (state: SavedState) => void;
  recordOutcome: (outcome: PlanningOutcome) => void;
  configure: (sessionId: string) => (() => void)[];
  ensureSubagentsIdle: (signal: AbortSignal) => Promise<void>;
  startInPlan: () => boolean;
  sendUserMessage: (
    message: string,
    options?: { deliverAs?: "steer"; expandPromptTemplates?: boolean },
  ) => void;
  sendImplementationMessage: (
    content: string | PlanningResult["content"],
    onError: (error: unknown) => void,
  ) => void;
  requestId: () => string;
  review: (ctx: ReviewContext, request: ReviewRequest) => Promise<ReviewResult>;
}

function exitMessage(
  state: PlanningSession,
): { customType: string; content: string; display: boolean } | undefined {
  if (!state.hasExitReminder()) {
    return undefined;
  }
  let path: string | undefined;
  try {
    if (state.store.exists()) {
      path = state.store.path;
    }
  } catch {
    path = undefined;
  }
  const message = {
    customType: exitReminderType,
    content: planExitReminder(path),
    display: false,
  };
  state.consumeExitReminder();
  return message;
}

function notify(
  context: PlanningContext,
  message: string,
  level: "info" | "warning" | "error",
): void {
  context.ui.notify(displayText(message), level);
}

export function createPlanning(dependencies: PlanningDependencies) {
  let session: PlanningSession | undefined;
  let ticket:
    | {
        token: string;
        decision: "current" | "clear";
        session: PlanningSession;
        plan: PlanRevision;
        feedback?: string;
        images: ImageContent[];
        phase: "approved" | "verified" | "settling";
        verificationSignal?: AbortSignal;
        summary?: string;
      }
    | undefined;
  let review: AbortController | undefined;
  let entryRequest: AbortController | undefined;
  let turnsSinceReminder = 0;
  let editing = false;

  function recordImplementationFailure(
    plan: PlanRevision,
    reason: string,
  ): void {
    dependencies.recordOutcome({
      version: 1,
      event: "implementation-failed",
      path: plan.path,
      revision: plan.revision,
      reason,
    });
  }

  function status(ctx: PlanningContext): void {
    ctx.ui.setStatus(
      "planning",
      session?.active === true ? "plan mode on" : undefined,
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

  function cancelEntry(): void {
    entryRequest?.abort();
    entryRequest = undefined;
  }

  function enter(ctx: PlanningContext, reassess = false): PlanningSession {
    cancelEntry();
    ticket = undefined;
    const state = current(ctx);
    configure(state);
    state.enter(reassess);
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
    cancelEntry();
    review?.abort();
    ticket = undefined;
    session?.dispose();
    turnsSinceReminder = 0;
    session = replacement;
    if (session.active) {
      try {
        configure(session);
      } catch (error) {
        notify(
          ctx,
          `Planning research is unavailable: ${String(error)}`,
          "error",
        );
      }
    }
    status(ctx);
  }

  function leave(ctx: PlanningContext): void {
    cancelEntry();
    ticket = undefined;
    review?.abort();
    current(ctx).setActive(false);
    status(ctx);
  }

  function showPlan(
    state: PlanningSession,
    ctx: PlanningContext,
    missingMessage:
      | string
      | null = `No plan has been written yet. Plan file: ${state.store.path}`,
  ): PlanRevision | undefined {
    try {
      if (!state.store.exists()) {
        if (missingMessage !== null) {
          notify(ctx, missingMessage, "info");
        }
        return undefined;
      }
      const plan = state.store.read();
      dependencies.presentPlan(plan);
      return plan;
    } catch (error) {
      notify(ctx, `Cannot display the plan: ${String(error)}`, "error");
      return undefined;
    }
  }

  async function editPlan(
    state: PlanningSession,
    ctx: PlanningContext,
    editor: PlanEditor | undefined,
  ): Promise<void> {
    if (editing || review) {
      notify(
        ctx,
        "Finish the active editor or review before opening the plan.",
        "error",
      );
      return;
    }
    if (!editor) {
      notify(ctx, "The plan editor is unavailable in this context.", "error");
      return;
    }
    if (!state.store.exists()) {
      showPlan(state, ctx);
      return;
    }
    const plan = state.store.read();
    const signal = AbortSignal.any([
      state.signal,
      ...(ctx.signal ? [ctx.signal] : []),
    ]);
    ticket = undefined;
    editing = true;
    let failure: string | undefined;
    try {
      await editor.open(plan.path);
    } catch (error) {
      failure = String(error);
    } finally {
      editing = false;
    }
    if (
      session !== state ||
      ctx.sessionManager.getSessionId() !== state.id ||
      signal.aborted
    ) {
      return;
    }
    const updated = showPlan(state, ctx);
    if (failure !== undefined) {
      notify(ctx, `Cannot edit the plan: ${failure}`, "error");
      return;
    }
    if (updated) {
      notify(
        ctx,
        updated.revision === plan.revision ? "Plan unchanged" : "Plan saved",
        "info",
      );
    }
  }

  const command = async (
    args: string,
    ctx: PlanningContext,
    editor?: PlanEditor,
  ): Promise<void> => {
    cancelEntry();
    review?.abort();
    ticket = undefined;
    const state = current(ctx);
    const action = args.trim();
    if (action === "exit") {
      leave(ctx);
      notify(ctx, "Exited plan mode", "info");
      return;
    }
    if (action === "review") {
      ticket = undefined;
      if (!state.active) {
        notify(ctx, "Enter Plan mode first.", "info");
        return;
      }
      dependencies.sendUserMessage(
        "Review the active plan, resolve any remaining questions, and call submit_plan.",
        { deliverAs: "steer" },
      );
      return;
    }
    if (action !== "" && action !== "open") {
      review?.abort();
      enter(ctx, true);
      dependencies.sendUserMessage(`Plan this task: ${action}`, {
        deliverAs: "steer",
      });
      return;
    }
    const entering = !state.active;
    if (entering) {
      enter(ctx);
      notify(ctx, "Enabled plan mode", "info");
    }
    if (action === "") {
      showPlan(
        state,
        ctx,
        entering ? null : "Already in plan mode. No plan written yet.",
      );
      return;
    }
    await editPlan(state, ctx, editor);
  };
  const toggle = (ctx: PlanningContext): void => {
    cancelEntry();
    const state = current(ctx);
    if (state.active) {
      leave(ctx);
      return;
    }
    enter(ctx);
  };

  const enterTool = async (
    ctx: PlanningContext,
    signal?: AbortSignal,
  ): Promise<PlanningResult<EnterPlanOutput>> => {
    signal?.throwIfAborted();
    const runSignal = ctx.signal;
    runSignal?.throwIfAborted();
    const state = current(ctx);
    if (!state.active) {
      if (!ctx.hasUI) {
        throw new Error(
          "Plan mode entry requires user consent. Use /plan or --plan to enter explicitly.",
        );
      }
      if (entryRequest) {
        throw new Error("A Plan mode entry request is already open.");
      }
      const pending = new AbortController();
      entryRequest = pending;
      const combined = AbortSignal.any([
        pending.signal,
        ...(signal ? [signal] : []),
        ...(runSignal ? [runSignal] : []),
      ]);
      let approved: unknown;
      try {
        approved = await ctx.ui.confirm(
          "Enter Plan mode?",
          "Pi will investigate and draft an implementation plan for your approval. Only the plan file may be edited in Plan mode. Entering does not approve implementation.",
          { signal: combined },
        );
        combined.throwIfAborted();
        if (
          session !== state ||
          ctx.sessionManager.getSessionId() !== state.id
        ) {
          throw new Error(
            "The planning session changed during entry confirmation.",
          );
        }
      } finally {
        if (entryRequest === pending) {
          entryRequest = undefined;
        }
      }
      if (approved !== true) {
        const instructions =
          "Plan mode was not entered. Continue in the current mode and follow the user's request.";
        return {
          content: [{ type: "text", text: instructions }],
          details: { status: "declined" },
          structuredContent: { status: "declined", instructions },
        };
      }
      enter(ctx);
    }
    const instructions = planningPrompt(
      state.store.path,
      state.consumeReassessment() && state.store.exists(),
    );
    return {
      content: [{ type: "text", text: instructions }],
      details: { status: "active", path: state.store.path },
      structuredContent: {
        status: "active",
        path: state.store.path,
        instructions,
      },
    };
  };
  const submit = async (
    ctx: PlanningContext,
    signal?: AbortSignal,
    onUpdate?: (result: PlanningResult) => void,
  ): Promise<PlanningResult<SubmitPlanOutput>> => {
    const state = current(ctx);
    if (!state.active) {
      throw new Error("Plan mode is not active.");
    }
    if (editing) {
      throw new Error("Finish editing the plan before requesting approval.");
    }
    if (review) {
      throw new Error("A plan review is already open.");
    }
    ticket = undefined;
    const plan = state.store.read();
    validatePlanDocument(plan);
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
        if (
          !combined.aborted &&
          (reviewed.decision === "current" || reviewed.decision === "clear")
        ) {
          await dependencies.ensureSubagentsIdle(combined);
        }
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
    const feedback =
      decision === "cancel" ||
      reviewed.feedback === undefined ||
      reviewed.feedback.trim() === ""
        ? undefined
        : reviewed.feedback;
    validateFeedbackText(feedback);
    const images =
      decision === "cancel"
        ? []
        : (reviewed.images ?? []).map(({ type, data, mimeType }) => ({
            type,
            data,
            mimeType,
          }));
    if (images.length > 0) {
      validateImageInput(ctx.model?.input);
    }
    const outcome: PlanningOutcome = {
      version: 1,
      event: "review",
      decision,
      path: presented.path,
      revision: presented.revision,
    };
    if (feedback !== undefined) {
      outcome.feedback = feedback;
    }
    if (images.length > 0) {
      outcome.images = images;
    }
    dependencies.recordOutcome(outcome);
    if (decision === "current" || decision === "clear") {
      const token = dependencies.requestId();
      ticket = {
        token,
        decision,
        session: state,
        plan: presented,
        feedback,
        images,
        phase: "approved",
      };
    }
    const messages = {
      current:
        "Plan approved. Finish this planning turn and wait for the implementation transition; do not edit project files yet.",
      clear:
        "Plan approved. Wait for context clearing; keep this conversation in planning until the transition finishes.",
      revise:
        feedback === undefined && images.length === 0
          ? "The user requested revisions. Continue planning and ask for the necessary feedback."
          : "The user requested revisions. Continue planning and incorporate their feedback.",
      cancel:
        "Plan review was cancelled. Continue planning; implementation has not been approved.",
    } satisfies Record<ReviewResult["decision"], string>;
    const reviewSummary = messages[decision];
    const content: PlanningResult["content"] = [
      { type: "text", text: reviewSummary },
    ];
    if (
      decision === "current" ||
      (decision !== "clear" && presented.revision !== plan.revision)
    ) {
      content.push({ type: "text", text: reviewedPlanContext(presented) });
    }
    if (feedback !== undefined) {
      content.push({ type: "text", text: reviewFeedbackContext(feedback) });
    }
    if (images.length > 0) {
      content.push({ type: "text", text: "User image feedback:" }, ...images);
    }
    const details: ReviewedPlanDetails = {
      formatVersion: 1,
      decision,
      path: presented.path,
      revision: presented.revision,
      presentedPlan: presented,
      reviewSummary,
    };
    const structuredContent: SubmitPlanOutput = {
      version: 1,
      decision,
      plan: presented,
      imageCount: images.length,
    };
    if (feedback !== undefined) {
      details.feedback = feedback;
      structuredContent.feedback = feedback;
    }
    return { content, details, structuredContent };
  };

  const toolCall = async (
    event: { toolName: string; input: Record<string, unknown> },
    ctx: PlanningContext,
  ): Promise<{ block: true; reason: string } | undefined> => {
    const state = current(ctx);
    if (!state.active) {
      return undefined;
    }
    return planningPolicy(
      event,
      ctx,
      state.store,
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
        systemPrompt: `${event.systemPrompt}\n\n${planningPrompt(state.store.path, state.consumeReassessment() && state.store.exists())}`,
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
    if (!approval) {
      return;
    }
    const runSignal = ctx.signal;
    if (
      session !== approval.session ||
      !approval.session.active ||
      runSignal?.aborted !== false
    ) {
      ticket = undefined;
      recordImplementationFailure(
        approval.plan,
        "Implementation approval was cancelled before verification.",
      );
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
      if (ticket !== pending) {
        return;
      }
      ticket = undefined;
      recordImplementationFailure(
        approval.plan,
        signal.aborted
          ? "Implementation approval was cancelled during research verification."
          : String(error),
      );
      if (!signal.aborted) {
        notify(
          ctx,
          `Cannot start approved implementation: ${String(error)}`,
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
    if (!approval) {
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
      recordImplementationFailure(
        approval.plan,
        event.outcome === "completed"
          ? "Implementation approval was no longer valid at settlement."
          : `The planning run ended (${event.outcome}) before implementation started.`,
      );
      return undefined;
    }
    if (!approval.session.store.matches(approval.plan)) {
      ticket = undefined;
      recordImplementationFailure(
        approval.plan,
        "The plan approval expired. Review the current file again.",
      );
      notify(
        ctx,
        "The plan approval expired. Review the current file again.",
        "error",
      );
      return undefined;
    }
    const source = ctx.sessionManager.getSessionFile() ?? approval.session.id;
    const summary = implementationContext(
      approval.plan,
      source,
      approval.feedback,
    );
    ticket = { ...approval, phase: "settling", summary };
    if (approval.decision === "current") {
      return undefined;
    }
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
    if (!approval) {
      return;
    }
    if (
      event.aborted ||
      approval.phase !== "settling" ||
      approval.verificationSignal?.aborted !== false ||
      session !== approval.session ||
      !approval.session.active
    ) {
      recordImplementationFailure(
        approval.plan,
        "Implementation approval was no longer valid after settlement.",
      );
      return;
    }
    if (
      approval.summary === undefined ||
      !approval.session.store.matches(approval.plan)
    ) {
      recordImplementationFailure(
        approval.plan,
        "The plan approval expired. Review the current file again.",
      );
      notify(
        ctx,
        "The plan approval expired. Review the current file again.",
        "error",
      );
      return;
    }
    if (approval.decision === "clear") {
      const entry = ctx.sessionManager
        .getBranch()
        .findLast((candidate) => Check(compactionTypeSchema, candidate));
      if (
        !Check(clearedContextSchema, entry) ||
        entry.firstKeptEntryId !== entry.id ||
        entry.details.token !== approval.token ||
        entry.summary !== approval.summary
      ) {
        recordImplementationFailure(
          approval.plan,
          "Context clearing was not confirmed for the approved revision. Review the plan again.",
        );
        notify(
          ctx,
          "Context clearing was not confirmed for the approved revision. Review the plan again.",
          "error",
        );
        return;
      }
    }
    const content: string | PlanningResult["content"] =
      approval.images.length === 0
        ? approval.summary
        : [
            { type: "text", text: approval.summary },
            { type: "text", text: "User image feedback:" },
            ...approval.images,
          ];
    let failureRecorded = false;
    const onError = (error: unknown): void => {
      if (failureRecorded) {
        return;
      }
      failureRecorded = true;
      const reason = String(error);
      recordImplementationFailure(approval.plan, reason);
      notify(ctx, reason, "error");
    };
    try {
      validateFeedbackText(approval.feedback);
      if (approval.images.length > 0) {
        validateImageInput(ctx.model?.input);
      }
      approval.session.setActive(false);
      approval.session.consumeExitReminder();
      status(ctx);
      dependencies.sendImplementationMessage(content, onError);
    } catch (error) {
      onError(error);
      throw error;
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
      notify(ctx, `Cannot restore plan context: ${String(error)}`, "warning");
    }
    return parts.length > 0 ? parts.join("\n\n") : undefined;
  };
  const shutdown = (): void => {
    cancelEntry();
    review?.abort();
    session?.dispose();
    ticket = undefined;
  };

  return {
    command,
    toggle,
    input: () => {
      cancelEntry();
      review?.abort();
      ticket = undefined;
    },
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
