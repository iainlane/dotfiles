import type { BoundaryResult } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it } from "vitest";
import {
  createPlanning,
  type PlanningContext,
  type PlanningDependencies,
  type PlanningResult,
} from "#planning/controller.ts";
import { researchPolicy } from "#planning/policy.ts";
import { displayPath } from "#planning/presentation.ts";
import {
  attachedPlanContext,
  enterPlanDescription,
  implementationContext,
  planExitReminder,
  planningPrompt,
} from "#planning/prompt.ts";
import {
  reviewPlan,
  type ReviewRequest,
  type ReviewResult,
} from "#planning/review.ts";
import { stateEntry } from "#planning/session.ts";
import { outcomeEntryType, type PlanningOutcome } from "#planning/outcomes.ts";
import type { PlanningStatus } from "#planning/status.ts";
import { PlanStore, type PlanRevision } from "#planning/store.ts";
import { MemoryFiles } from "./memory-files.ts";
import { feedbackImage } from "./fixtures/image.ts";

const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) {
    cleanup();
  }
});

const activeSubagent =
  "A subagent is still active. Wait for completion or cancel it before requesting implementation approval.";

type Answer<T> = () => T | Promise<T>;

type Dialog = { state: "open" | "answered" | "dismissed" } & (
  | { kind: "confirm"; title: string; message: string }
  | { kind: "select"; title: string; options: string[] }
  | { kind: "input"; title: string; placeholder: string | undefined }
);

type ConversationMessage =
  | {
      kind: "user";
      text: string;
      options: Parameters<PlanningDependencies["sendUserMessage"]>[1];
    }
  | {
      kind: "implementation";
      content: Parameters<PlanningDependencies["sendImplementationMessage"]>[0];
    };

function review(
  context: Parameters<PlanningDependencies["review"]>[0],
  request: ReviewRequest,
) {
  return reviewPlan(context, request, { name: "nvim", open: async () => {} });
}

type ScriptedReview =
  | ReviewResult
  | ((request: ReviewRequest) => Promise<ReviewResult>);

function fixture(
  branch: unknown[] = [],
  initialId = "session-one",
  seed?: (open: (id: string) => PlanStore) => void,
) {
  const directory = "/planning-fixture";
  const files = new MemoryFiles();
  const openPlan = (id: string) =>
    new PlanStore(`${directory}/plans`, id, files);
  const session = { id: initialId };
  const pi = {
    conversation: [] as ConversationMessage[],
    outcomes: [] as PlanningOutcome[],
    transcript: [] as PlanRevision[],
    notifications: [] as { message: string; level: string | undefined }[],
    statuses: new Map<string, string>(),
    published: undefined as PlanningStatus | undefined,
    reviewAvailable: false,
    dialogs: [] as Dialog[],
    planFlag: false,
    research: [] as string[],
    activeSubagents: 0,
    journalFailure: undefined as Error | undefined,
    launchFailure: undefined as Error | undefined,
    researchFailure: undefined as Error | undefined,
  };
  const answers = {
    confirm: [] as Answer<boolean>[],
    select: [] as Answer<string | undefined>[],
    input: [] as Answer<string | undefined>[],
  };
  const reviews: ScriptedReview[] = [];
  let heldStatus:
    | {
        reached: PromiseWithResolvers<void>;
        release: PromiseWithResolvers<void>;
      }
    | undefined;
  const ask = async <T>(
    dialog: Dialog,
    script: Answer<T>[],
    fallback: T,
    signal: AbortSignal | undefined,
  ): Promise<T> => {
    pi.dialogs.push(dialog);
    const dismiss = () => {
      if (dialog.state === "open") {
        dialog.state = "dismissed";
      }
    };
    signal?.addEventListener("abort", dismiss, { once: true });
    try {
      const answer = script.shift();
      const value = answer === undefined ? fallback : await answer();
      if (dialog.state === "open") {
        dialog.state = "answered";
      }
      return value;
    } finally {
      signal?.removeEventListener("abort", dismiss);
    }
  };
  const editor = {
    name: "fixture-editor",
    saves: undefined as string | undefined,
    failure: undefined as Error | undefined,
    closed: Promise.resolve(),
    async open(path: string) {
      await editor.closed;
      if (editor.saves !== undefined) {
        files.replace(path, editor.saves);
      }
      if (editor.failure) {
        throw editor.failure;
      }
    },
  };
  const run = new AbortController();
  const ctx: PlanningContext = {
    signal: run.signal,
    cwd: directory,
    mode: "rpc",
    hasUI: true,
    model: { input: ["text", "image"] },
    sessionManager: {
      getSessionId: () => session.id,
      getBranch: () => branch,
      getSessionFile: () => "/fixture/session.jsonl",
    },
    ui: {
      notify: (message, level) => {
        pi.notifications.push({ message, level });
      },
      setStatus: (key, text) => {
        if (text === undefined) {
          pi.statuses.delete(key);
          return;
        }
        pi.statuses.set(key, text);
      },
      select: (title, options, opts) =>
        ask(
          { kind: "select", title, options, state: "open" },
          answers.select,
          undefined,
          opts?.signal,
        ),
      input: (title, placeholder, opts) =>
        ask(
          { kind: "input", title, placeholder, state: "open" },
          answers.input,
          undefined,
          opts?.signal,
        ),
      confirm: (title, message, opts) =>
        ask(
          { kind: "confirm", title, message, state: "open" },
          answers.confirm,
          false,
          opts?.signal,
        ),
      getToolsExpanded: () => false,
      setToolsExpanded: () => {},
      custom: async () => ({
        decision: "cancel",
        presentedPlan: { path: "", revision: "", content: "" },
      }),
    },
  };
  const ensureSubagentsIdle = async (signal: AbortSignal) => {
    signal.throwIfAborted();
    const held = heldStatus;
    if (held) {
      held.reached.resolve();
      const cancelled = Promise.withResolvers<void>();
      const cancel = () =>
        cancelled.reject(new Error("The subagent status check was cancelled."));
      signal.addEventListener("abort", cancel, { once: true });
      void (async () => {
        await held.release.promise;
        cancelled.resolve();
      })();
      try {
        await cancelled.promise;
      } finally {
        signal.removeEventListener("abort", cancel);
      }
    }
    if (pi.activeSubagents > 0) {
      throw new Error(activeSubagent);
    }
  };
  let identity = 0;
  const controller = createPlanning({
    openPlan,
    configure: (sessionId) => {
      if (pi.researchFailure) {
        throw pi.researchFailure;
      }
      pi.research.push(sessionId);
      return [
        () => {
          pi.research.splice(pi.research.indexOf(sessionId), 1);
        },
      ];
    },
    publishStatus: (status) => {
      pi.published = status;
    },
    presentPlan: (plan) => {
      pi.transcript.push(plan);
    },
    sendUserMessage: (text, options) => {
      pi.conversation.push({ kind: "user", text, options });
    },
    sendImplementationMessage: (content) => {
      if (pi.launchFailure) {
        throw pi.launchFailure;
      }
      pi.conversation.push({ kind: "implementation", content });
    },
    recordOutcome: (outcome) => {
      if (pi.journalFailure) {
        throw pi.journalFailure;
      }
      pi.outcomes.push(outcome);
    },
    recordSavedState: (data) => {
      branch.push({ type: "custom", customType: stateEntry, data });
    },
    ensureSubagentsIdle,
    startInPlan: () => pi.planFlag,
    setReviewAvailable: (available) => {
      pi.reviewAvailable = available;
    },
    requestId: () => `ticket-${++identity}`,
    review: (context, request) => {
      const scripted = reviews.shift();
      if (scripted === undefined) {
        return review(context, request);
      }
      return typeof scripted === "function"
        ? scripted(request)
        : Promise.resolve(scripted);
    },
  });
  seed?.(openPlan);
  controller.start({ reason: "startup" }, ctx);
  cleanups.push(() => controller.shutdown());
  const prepareClear = async (
    event: Parameters<typeof controller.beforeSettle>[0],
    context: PlanningContext,
  ) => {
    await controller.verifyClear(context);
    return controller.beforeSettle(event, context);
  };
  const command = (args: string) => controller.command(args, ctx, editor);
  const execute = (_name: "submit_plan", _params = {}, signal?: AbortSignal) =>
    controller.submit(ctx, signal);
  const call = (toolName: string, input: Record<string, unknown>) =>
    controller.toolCall({ toolName, input }, ctx);
  const path = () => openPlan(ctx.sessionManager.getSessionId()).path;
  const commit = (boundary: BoundaryResult | undefined) => {
    for (const entry of boundary?.entries ?? []) {
      const id = `compaction-${branch.length}`;
      branch.push(
        entry.type === "compaction"
          ? { ...entry, id, firstKeptEntryId: entry.firstKeptEntryId ?? id }
          : entry,
      );
    }
  };
  return {
    pi,
    session,
    answers,
    reviews,
    review,
    holdStatus: () => {
      const held = {
        reached: Promise.withResolvers<void>(),
        release: Promise.withResolvers<void>(),
      };
      heldStatus = held;
      return {
        reached: held.reached.promise,
        release: () => {
          heldStatus = undefined;
          held.release.resolve();
        },
      };
    },
    directory,
    branch,
    controller,
    prepareClear,
    run,
    ctx,
    command,
    execute,
    call,
    path,
    editor,
    files,
    openPlan,
    commit,
    completeApproval: async () => {
      commit(await prepareClear({ outcome: "completed" }, ctx));
      controller.settled({ aborted: false }, ctx);
    },
  };
}

it("publishes semantic active state alongside the standalone native fallback", async () => {
  const h = fixture();
  const status = () => ({
    published: h.pi.published,
    native: h.pi.statuses.get("planning"),
  });
  const initial = status();
  await h.command("");
  const entered = status();
  await h.command("exit");
  const exited = status();
  h.controller.restore({
    ...h.ctx,
    sessionManager: {
      ...h.ctx.sessionManager,
      getSessionId: () => "session-two",
      getBranch: () => [],
    },
  });
  expect({ initial, entered, exited, restored: status() }).toStrictEqual({
    initial: {
      published: { sessionId: "session-one", active: false },
      native: undefined,
    },
    entered: {
      published: { sessionId: "session-one", active: true },
      native: "plan mode on",
    },
    exited: {
      published: { sessionId: "session-one", active: false },
      native: undefined,
    },
    restored: {
      published: { sessionId: "session-two", active: false },
      native: undefined,
    },
  });
});

it("retains Claude's planning criteria without treating ordinary work as an entry trigger", () => {
  expect({
    criteria: [...enterPlanDescription.matchAll(/^\d\. \*\*([^*]+)\*\*/gm)].map(
      (match) => match[1],
    ),
    automaticTriggers: enterPlanDescription.includes(
      "Use it when ANY of these conditions apply",
    ),
    requiresPlanningBeforeClarification: enterPlanDescription.includes(
      "use enter_plan_mode first",
    ),
    boundedWork: enterPlanDescription.includes(
      "Bounded fixes and small features with clear requirements, including their tests",
    ),
    ordinaryInvestigation: enterPlanDescription.includes(
      "Investigation, file count and focused clarification alone do not require Plan mode.",
    ),
    uncertainEntry: enterPlanDescription.includes(
      "If unsure whether to use it, prefer asking to enter Plan mode",
    ),
  }).toStrictEqual({
    criteria: [
      "New Feature Implementation",
      "Multiple Valid Approaches",
      "Code Modifications",
      "Architectural Decisions",
      "Multi-File Changes",
      "Unclear Requirements",
      "User Preferences Matter",
    ],
    automaticTriggers: false,
    requiresPlanningBeforeClarification: false,
    boundedWork: true,
    ordinaryInvestigation: true,
    uncertainEntry: false,
  });
});

it.each(["a", "🦉"])(
  "accepts the complete 200,000 UTF-16-unit plan at the boundary: %s",
  async (character) => {
    const f = fixture();
    await f.command("");
    const content = character.repeat(200_000 / character.length);
    f.files.replace(f.path(), content);
    const result = await f.execute("submit_plan");
    expect({
      decision: result.details.decision,
      dialogs: f.pi.dialogs,
    }).toStrictEqual({
      decision: "cancel",
      dialogs: [
        {
          kind: "select",
          title: `Review plan ${displayPath(f.path())}\n\n${content}`,
          options: [
            "Yes, keep context",
            "Yes, clear context",
            "No, keep planning",
            "Continue planning",
            "Add a comment",
          ],
          state: "answered",
        },
      ],
    });
  },
);

it.each(["a", "🦉"])(
  "refuses oversized plans before opening review: %s",
  async (character) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), character.repeat(200_000 / character.length + 1));
    await expect(f.execute("submit_plan")).rejects.toThrow("200,000 UTF-16");
    expect({
      dialogs: f.pi.dialogs,
      conversation: f.pi.conversation,
    }).toStrictEqual({ dialogs: [], conversation: [] });
  },
);

it.each(["current", "clear", "revise", "cancel"] as const)(
  "returns genuine structured output for a %s review",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Context\nImplement the requested change.\n");
    const plan = f.openPlan("session-one").read();
    f.reviews.push({
      decision,
      presentedPlan: plan,
      feedback: "Keep the API.",
      images: [feedbackImage],
    });
    const result = await f.execute("submit_plan");
    expect(result.structuredContent).toStrictEqual({
      version: 1,
      decision,
      plan,
      imageCount: decision === "cancel" ? 0 : 1,
      ...(decision === "cancel" ? {} : { feedback: "Keep the API." }),
    });
  },
);

it.each(["current", "clear", "revise", "cancel"] as const)(
  "records a separate durable %s outcome with native feedback",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Context\nRequested work.\n");
    const plan = f.openPlan("session-one").read();
    f.reviews.push({
      decision,
      presentedPlan: plan,
      feedback: "Keep the API.",
      images: [feedbackImage],
    });
    await f.execute("submit_plan");
    expect(f.pi.outcomes).toStrictEqual([
      {
        version: 1,
        event: "review",
        decision,
        path: plan.path,
        revision: plan.revision,
        ...(decision === "cancel"
          ? {}
          : { feedback: "Keep the API.", images: [feedbackImage] }),
      },
    ]);
  },
);

it.each([undefined, { input: ["text"] }] satisfies PlanningContext["model"][])(
  "refuses image approval without native model image support: %j",
  async (model) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Context\nRequested work.\n");
    f.ctx.model = model;
    const plan = f.openPlan("session-one").read();
    f.reviews.push({
      decision: "current",
      presentedPlan: plan,
      images: [feedbackImage],
    });
    await expect(f.execute("submit_plan")).rejects.toThrow(
      "image-capable model",
    );
    await f.completeApproval();
    expect({
      outcomes: f.pi.outcomes,
      conversation: f.pi.conversation,
    }).toStrictEqual({ outcomes: [], conversation: [] });
  },
);

it.each([
  { feedback: "x".repeat(200_001), message: "200,000 UTF-16" },
  { feedback: "\uD800", message: "invalid Unicode" },
])(
  "refuses feedback outside the deliverable text policy: $message",
  async ({ feedback, message }) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Context\nRequested work.\n");
    f.reviews.push({
      decision: "current",
      presentedPlan: f.openPlan("session-one").read(),
      feedback,
    });
    await expect(f.execute("submit_plan")).rejects.toThrow(message);
    await f.completeApproval();
    expect({
      outcomes: f.pi.outcomes,
      conversation: f.pi.conversation,
    }).toStrictEqual({ outcomes: [], conversation: [] });
  },
);

it("does not restore implementation authority from persisted approval outcomes", async () => {
  const f = fixture(
    [
      {
        type: "custom",
        customType: stateEntry,
        data: { version: 1, active: true, sourceSessionId: "session-one" },
      },
    ],
    "session-one",
    (open) => {
      open("session-one").write("# Context\nRequested work.\n");
    },
  );
  const plan = f.openPlan("session-one").read();
  f.branch.push({
    type: "custom",
    customType: outcomeEntryType,
    data: {
      version: 1,
      event: "review",
      decision: "current",
      path: plan.path,
      revision: plan.revision,
    },
  });
  f.controller.restore(f.ctx);
  await f.completeApproval();
  expect({
    conversation: f.pi.conversation,
    guarded: (await f.call("write", { path: "project.ts" }))?.block,
  }).toStrictEqual({ conversation: [], guarded: true });
});

it("does not start image-based implementation after the model loses image support", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  f.reviews.push({
    decision: "current",
    presentedPlan: f.openPlan("session-one").read(),
    images: [feedbackImage],
  });
  await f.execute("submit_plan");
  f.ctx.model = { input: ["text"] };
  await expect(f.completeApproval()).rejects.toThrow("image-capable model");
  f.controller.settled({ aborted: false }, f.ctx);
  expect({
    conversation: f.pi.conversation,
    guarded: (await f.call("write", { path: "project.ts" }))?.block,
  }).toStrictEqual({ conversation: [], guarded: true });
});

it("does not grant implementation when the outcome cannot be persisted", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  const plan = f.openPlan("session-one").read();
  f.reviews.push({ decision: "current", presentedPlan: plan });
  f.pi.journalFailure = new Error("Journal unavailable");
  await expect(f.execute("submit_plan")).rejects.toThrow("Journal unavailable");
  f.pi.journalFailure = undefined;
  await f.completeApproval();
  expect({
    outcomes: f.pi.outcomes,
    conversation: f.pi.conversation,
  }).toStrictEqual({ outcomes: [], conversation: [] });
});

it.each([
  {
    stage: "verification",
    decision: "current",
    reason: `Error: ${activeSubagent}`,
  },
  {
    stage: "boundary",
    decision: "current",
    reason: "The plan approval expired. Review the current file again.",
  },
  {
    stage: "clear-commit",
    decision: "clear",
    reason:
      "Context clearing was not confirmed for the approved revision. Review the plan again.",
  },
  {
    stage: "aborted",
    decision: "current",
    reason: "The planning run ended (aborted) before implementation started.",
  },
] as const)(
  "records a durable failure when approval stops at $stage",
  async ({ stage, decision, reason }) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Context\nRequested work.\n");
    const plan = f.openPlan("session-one").read();
    f.reviews.push({ decision, presentedPlan: plan });
    await f.execute("submit_plan");
    if (stage === "verification") {
      f.pi.activeSubagents = 1;
      await f.controller.verifyClear(f.ctx);
    }
    if (stage === "boundary") {
      await f.controller.verifyClear(f.ctx);
      f.files.replace(f.path(), "# Changed plan\n");
      f.controller.beforeSettle({ outcome: "completed" }, f.ctx);
    }
    if (stage === "clear-commit") {
      await f.prepareClear({ outcome: "completed" }, f.ctx);
    }
    if (stage === "aborted") {
      f.controller.beforeSettle({ outcome: "aborted" }, f.ctx);
    }
    f.controller.settled({ aborted: stage === "aborted" }, f.ctx);
    expect({
      outcomes: f.pi.outcomes,
      conversation: f.pi.conversation,
    }).toStrictEqual({
      outcomes: [
        {
          version: 1,
          event: "review",
          decision,
          path: plan.path,
          revision: plan.revision,
        },
        {
          version: 1,
          event: "implementation-failed",
          path: plan.path,
          revision: plan.revision,
          reason,
        },
      ],
      conversation: [],
    });
  },
);

it("records a failed implementation launch and never retries the consumed approval", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  const plan = f.openPlan("session-one").read();
  f.reviews.push({ decision: "current", presentedPlan: plan });
  f.pi.launchFailure = new Error("Launch failed");
  await f.execute("submit_plan");
  await expect(f.completeApproval()).rejects.toThrow("Launch failed");
  f.pi.launchFailure = undefined;
  f.controller.settled({ aborted: false }, f.ctx);
  expect({
    outcomes: f.pi.outcomes,
    conversation: f.pi.conversation,
  }).toStrictEqual({
    outcomes: [
      {
        version: 1,
        event: "review",
        decision: "current",
        path: plan.path,
        revision: plan.revision,
      },
      {
        version: 1,
        event: "implementation-failed",
        path: plan.path,
        revision: plan.revision,
        reason: "Error: Launch failed",
      },
    ],
    conversation: [],
  });
});

it.each(["input", "show", "review", "open", "exit"])(
  "does not revive approval after %s during the post-review idle check",
  async (action) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Context\nRequested work.\n");
    const plan = f.openPlan("session-one").read();
    const held = Promise.withResolvers<ReturnType<typeof f.holdStatus>>();
    f.reviews.push(async () => {
      held.resolve(f.holdStatus());
      return { decision: "current", presentedPlan: plan };
    });
    const submitted = f.execute("submit_plan");
    const status = await held.promise;
    await Promise.race([
      status.reached,
      (async () => {
        await submitted;
        throw new Error("submit_plan finished before the second idle check.");
      })(),
    ]);
    if (action === "input") {
      f.controller.input();
    } else {
      await f.command(action === "show" ? "" : action);
    }
    status.release();
    const result = await submitted;
    await f.completeApproval();
    expect({
      decision: result.details.decision,
      implementation: f.pi.conversation.filter(
        ({ kind }) => kind === "implementation",
      ),
    }).toStrictEqual({ decision: "cancel", implementation: [] });
  },
);

it("rechecks idle research after the approval choice before accepting it", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  const plan = f.openPlan("session-one").read();
  f.reviews.push(async () => {
    f.pi.activeSubagents = 1;
    return { decision: "current", presentedPlan: plan };
  });
  await expect(f.execute("submit_plan")).rejects.toThrow(activeSubagent);
  await f.completeApproval();
  expect({
    outcomes: f.pi.outcomes,
    conversation: f.pi.conversation,
  }).toStrictEqual({ outcomes: [], conversation: [] });
});

it.each([
  { alreadyActive: false, message: "Enabled plan mode" },
  {
    alreadyActive: true,
    message: "Already in plan mode. No plan written yet.",
  },
])(
  "acknowledges /plan without a draft (already active: $alreadyActive)",
  async ({ alreadyActive, message }) => {
    const f = fixture();
    if (alreadyActive) {
      f.controller.toggle(f.ctx);
    }
    await f.command("");
    expect({
      notifications: f.pi.notifications,
      exists: f.openPlan("session-one").exists(),
      transcript: f.pi.transcript,
      active: (await f.call("write", { path: "project.ts" }))?.block,
      conversation: f.pi.conversation,
    }).toStrictEqual({
      notifications: [{ message, level: "info" }],
      exists: false,
      transcript: [],
      active: true,
      conversation: [],
    });
  },
);

it("enters lazily and shows the saved plan without toggling off or starting a turn", async () => {
  const f = fixture();
  await f.command("");
  const initiallyMissing = !f.openPlan("session-one").exists();
  f.files.replace(f.path(), "# Saved plan\n");
  const plan = f.openPlan("session-one").read();
  await f.command("");
  await f.command("");

  expect({
    initiallyMissing,
    transcript: f.pi.transcript,
    active: (await f.call("write", { path: "project.ts" }))?.block,
    research: f.pi.research,
    conversation: f.pi.conversation,
  }).toStrictEqual({
    initiallyMissing: true,
    transcript: [plan, plan],
    active: true,
    research: ["session-one"],
    conversation: [],
  });
});

it.each([false, true])(
  "opens the actual saved plan without approval (editor failure: %s)",
  async (failure) => {
    const f = fixture();
    f.files.replace(f.path(), "# Earlier plan\n");
    f.editor.saves = "# Saved editor changes\n";
    f.editor.failure = failure ? new Error("Fixture editor failed") : undefined;
    await f.command("open");
    expect({
      saved: f.files.read(f.path()),
      transcript: f.pi.transcript,
      active: (await f.call("write", { path: "project.ts" }))?.block,
      conversation: f.pi.conversation,
    }).toStrictEqual({
      saved: "# Saved editor changes\n",
      transcript: [f.openPlan("session-one").read()],
      active: true,
      conversation: [],
    });
  },
);

it("escapes untrusted editor errors before native notifications", async () => {
  const f = fixture();
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  f.editor.failure = new Error("\u001B[8mconcealed\u001B[0m");
  await f.command("open");
  expect(f.pi.notifications).toStrictEqual([
    { message: "Enabled plan mode", level: "info" },
    {
      message: "Cannot edit the plan: Error: \\u001b[8mconcealed\\u001b[0m",
      level: "error",
    },
  ]);
});

it("does not manufacture a plan when open is requested before the first write", async () => {
  const f = fixture();
  f.editor.saves = "# Editor contents\n";
  await f.command("open");
  expect({
    exists: f.openPlan("session-one").exists(),
    conversation: f.pi.conversation,
  }).toStrictEqual({ exists: false, conversation: [] });
});

it("delivers reassessment once across restoration and later runs", async () => {
  const f = fixture();
  f.files.replace(f.path(), "# Previous task\n");
  await f.command("");
  f.controller.restore(f.ctx);
  const first = f.controller.prompt({ systemPrompt: "Base" }, f.ctx);
  f.controller.restore(f.ctx);
  const next = f.controller.prompt({ systemPrompt: "Base" }, f.ctx);

  expect({ first, next }).toStrictEqual({
    first: { systemPrompt: `Base\n\n${planningPrompt(f.path(), true)}` },
    next: { systemPrompt: `Base\n\n${planningPrompt(f.path())}` },
  });
});

it.each(["exit", "restore", "shutdown"] as const)(
  "does not publish late editor results after %s",
  async (action) => {
    const f = fixture();
    f.files.replace(f.path(), "# Saved plan\n");
    const finished = Promise.withResolvers<void>();
    f.editor.closed = finished.promise;
    const opening = f.command("open");
    await expect(f.execute("submit_plan")).rejects.toThrow("Finish editing");
    if (action === "exit") {
      await f.command("exit");
    }
    if (action === "restore") {
      f.controller.restore(f.ctx);
    }
    if (action === "shutdown") {
      f.controller.shutdown();
    }
    finished.resolve();
    await opening;
    expect({
      transcript: f.pi.transcript,
      conversation: f.pi.conversation,
    }).toStrictEqual({ transcript: [], conversation: [] });
  },
);

it.each([
  { decision: "current", action: "" },
  { decision: "clear", action: "" },
  { decision: "current", action: "open" },
  { decision: "clear", action: "open" },
  { decision: "current", action: "exit" },
  { decision: "clear", action: "exit" },
] as const)(
  "revokes verified $decision approval on /plan $action",
  async ({ decision, action }) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Ready plan\n");
    f.reviews.push({
      decision,
      presentedPlan: f.openPlan("session-one").read(),
    });
    await f.execute("submit_plan");
    await f.controller.verifyClear(f.ctx);
    await f.command(action);
    const boundary = f.controller.beforeSettle({ outcome: "completed" }, f.ctx);
    f.commit(boundary);
    f.controller.settled({ aborted: false }, f.ctx);

    expect({
      boundary,
      conversation: f.pi.conversation,
    }).toStrictEqual({ boundary: undefined, conversation: [] });
  },
);

it("delivers a pathless exit notice when plan metadata is unreadable", async () => {
  const f = fixture();
  await f.command("");
  await f.command("exit");
  f.files.failures.set(f.path(), new Error("Metadata failure"));
  expect({
    first: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
    next: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
  }).toStrictEqual({
    first: {
      message: {
        customType: "dotfiles:planning-exit:v1",
        content: planExitReminder(),
        display: false,
      },
    },
    next: undefined,
  });
});

it.each(["current", "clear"] as const)(
  "preserves native image feedback through %s implementation hand-off",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    const plan = f.openPlan("session-one").read();
    f.reviews.push({
      decision,
      presentedPlan: plan,
      images: [feedbackImage],
    });
    const result = await f.execute("submit_plan");
    const boundary = await f.prepareClear({ outcome: "completed" }, f.ctx);
    f.commit(boundary);
    f.controller.settled({ aborted: false }, f.ctx);
    expect({
      images: result.content.filter((entry) => entry.type === "image"),
      conversation: f.pi.conversation,
      imageInSummary:
        boundary?.entries?.some(
          (entry) =>
            entry.type === "compaction" &&
            entry.summary.includes(feedbackImage.data),
        ) ?? false,
    }).toStrictEqual({
      images: [feedbackImage],
      conversation: [
        {
          kind: "implementation",
          content: [
            {
              type: "text",
              text: implementationContext(plan, "/fixture/session.jsonl"),
            },
            { type: "text", text: "User image feedback:" },
            feedbackImage,
          ],
        },
      ],
      imageInSummary: false,
    });
  },
);

it("waits for entry consent before creating a plan or restricting tools", async () => {
  const f = fixture();
  const answer = Promise.withResolvers<boolean>();
  f.answers.confirm.push(() => answer.promise);
  const entering = f.controller.enterTool(f.ctx);

  expect({
    dialogs: f.pi.dialogs,
    planExists: f.openPlan("session-one").exists(),
    research: f.pi.research,
    saved: f.branch,
    projectWrite: await f.call("write", { path: "project.ts" }),
  }).toStrictEqual({
    dialogs: [
      {
        kind: "confirm",
        title: "Enter Plan mode?",
        message:
          "Pi will investigate and draft an implementation plan for your approval. Only the plan file may be edited in Plan mode. Entering does not approve implementation.",
        state: "open",
      },
    ],
    planExists: false,
    research: [],
    saved: [],
    projectWrite: undefined,
  });

  answer.resolve(true);
  const result = await entering;
  const instructions = planningPrompt(f.path());
  expect({
    result,
    planExists: f.openPlan("session-one").exists(),
    research: f.pi.research,
    projectWrite: await f.call("write", { path: "project.ts" }),
  }).toStrictEqual({
    result: {
      content: [{ type: "text", text: instructions }],
      details: { status: "active", path: f.path() },
      structuredContent: { status: "active", path: f.path(), instructions },
    },
    planExists: false,
    research: ["session-one"],
    projectWrite: {
      block: true,
      reason: `Only the active plan may be edited: ${f.path()}`,
    },
  });
});

it("keeps ordinary mode when entry consent is declined or cancelled", async () => {
  const f = fixture();
  f.answers.confirm.push(() => false);
  const instructions =
    "Plan mode was not entered. Continue in the current mode and follow the user's request.";
  expect({
    result: await f.controller.enterTool(f.ctx),
    planExists: f.openPlan("session-one").exists(),
    research: f.pi.research,
    saved: f.branch,
    projectWrite: await f.call("write", { path: "project.ts" }),
  }).toStrictEqual({
    result: {
      content: [{ type: "text", text: instructions }],
      details: { status: "declined" },
      structuredContent: { status: "declined", instructions },
    },
    planExists: false,
    research: [],
    saved: [],
    projectWrite: undefined,
  });
});

it("refuses model-requested entry without a consent UI", async () => {
  const f = fixture();
  f.ctx.hasUI = false;
  await expect(f.controller.enterTool(f.ctx)).rejects.toThrow(
    "Plan mode entry requires user consent",
  );
  expect({
    dialogs: f.pi.dialogs,
    planExists: f.openPlan("session-one").exists(),
    research: f.pi.research,
    saved: f.branch,
  }).toStrictEqual({
    dialogs: [],
    planExists: false,
    research: [],
    saved: [],
  });
});

it.each(["tool", "run", "restore", "shutdown", "human exit"] as const)(
  "rejects a late affirmative entry response after %s cancellation",
  async (cause) => {
    const f = fixture();
    const answer = Promise.withResolvers<boolean>();
    const tool = new AbortController();
    f.answers.confirm.push(() => answer.promise);
    const entering = f.controller.enterTool(f.ctx, tool.signal);
    if (cause === "tool") {
      tool.abort();
    }
    if (cause === "run") {
      f.run.abort();
    }
    if (cause === "restore") {
      f.controller.restore(f.ctx);
    }
    if (cause === "shutdown") {
      f.controller.shutdown();
    }
    if (cause === "human exit") {
      f.controller.toggle(f.ctx);
      f.controller.toggle(f.ctx);
    }
    answer.resolve(true);
    await expect(entering).rejects.toThrow("aborted");
    expect({
      dialogs: f.pi.dialogs.map(({ kind, state }) => ({ kind, state })),
      projectWrite: await f.call("write", { path: "project.ts" }),
      savedActive: f.branch.at(-1),
    }).toStrictEqual({
      dialogs: [{ kind: "confirm", state: "dismissed" }],
      projectWrite: undefined,
      savedActive:
        cause === "human exit"
          ? {
              type: "custom",
              customType: stateEntry,
              data: {
                version: 1,
                active: false,
                sourceSessionId: "session-one",
                exitReminderPending: true,
              },
            }
          : undefined,
    });
  },
);

it("rejects consent for a different session identity", async () => {
  const f = fixture();
  const answer = Promise.withResolvers<boolean>();
  f.answers.confirm.push(() => answer.promise);
  const entering = f.controller.enterTool(f.ctx);
  f.session.id = "replacement";
  answer.resolve(true);
  await expect(entering).rejects.toThrow("session changed");
  expect(f.pi.research).toStrictEqual([]);
});

it("does not open overlapping entry requests", async () => {
  const f = fixture();
  const answer = Promise.withResolvers<boolean>();
  f.answers.confirm.push(() => answer.promise);
  const entering = f.controller.enterTool(f.ctx);
  await expect(f.controller.enterTool(f.ctx)).rejects.toThrow(
    "entry request is already open",
  );
  answer.resolve(false);
  await entering;
  expect(
    f.pi.dialogs.map(({ kind, state }) => ({ kind, state })),
  ).toStrictEqual([{ kind: "confirm", state: "answered" }]);
});

it("does not request entry consent again while Plan mode is active", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Existing draft\n");
  await f.controller.enterTool(f.ctx);
  expect({
    dialogs: f.pi.dialogs,
    draft: f.files.read(f.path()),
    research: f.pi.research,
  }).toStrictEqual({
    dialogs: [],
    draft: "# Existing draft\n",
    research: ["session-one"],
  });
});

it("can request consent again after leaving Plan mode", async () => {
  const f = fixture();
  await f.command("");
  await f.command("exit");
  f.answers.confirm.push(() => true);
  await f.controller.enterTool(f.ctx);
  expect({
    dialogs: f.pi.dialogs.map(({ kind, state }) => ({ kind, state })),
    projectWrite: (await f.call("write", { path: "project.ts" }))?.block,
  }).toStrictEqual({
    dialogs: [{ kind: "confirm", state: "answered" }],
    projectWrite: true,
  });
});

it("honours the explicit startup flag without a consent UI", () => {
  const f = fixture();
  f.ctx.hasUI = false;
  f.pi.planFlag = true;
  f.controller.start({ reason: "startup" }, f.ctx);
  expect({
    reviewAvailable: f.pi.reviewAvailable,
    dialogs: f.pi.dialogs,
    planExists: f.openPlan("session-one").exists(),
    research: f.pi.research,
  }).toStrictEqual({
    reviewAvailable: true,
    dialogs: [],
    planExists: false,
    research: ["session-one"],
  });
});

it("enters without a model call, preserves drafts, and releases child capabilities on exit", async () => {
  const f = fixture();
  await f.command("");
  const path = f.path();
  f.files.replace(path, "# Existing draft\n");
  const entered = [...f.pi.research];
  await f.command("exit");
  const exited = [...f.pi.research];
  await f.command("");
  expect({
    entered,
    exited,
    reentered: f.pi.research,
    draft: f.files.read(f.path()),
    conversation: f.pi.conversation,
  }).toStrictEqual({
    entered: ["session-one"],
    exited: [],
    reentered: ["session-one"],
    draft: "# Existing draft\n",
    conversation: [],
  });
});

it("refreshes planning guidance across turns, compaction and re-entry", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Current plan\n");
  const event = { outcome: "completed" as const };
  const turns = Array.from({ length: 5 }, () =>
    f.controller.turnEnd(event, f.ctx),
  );
  const reminder = `Plan mode remains active. Research tools and read-only delegation are available. Only the active plan may be edited: ${f.path()}\nUse ask_user to clarify requirements and submit_plan to request implementation approval.`;
  expect({
    turns,
    compact: f.controller.compact(f.ctx),
    prompt: f.controller.prompt({ systemPrompt: "Base instructions" }, f.ctx),
  }).toStrictEqual({
    turns: [
      undefined,
      undefined,
      undefined,
      undefined,
      {
        entries: [
          {
            type: "custom_message",
            customType: "dotfiles:planning-reminder:v1",
            content: reminder,
            display: false,
          },
        ],
      },
    ],
    compact: `${reminder}\n\n${attachedPlanContext(f.openPlan("session-one").read())}`,
    prompt: {
      systemPrompt: `Base instructions\n\n${planningPrompt(f.path())}`,
    },
  });
  await f.command("exit");
  expect({
    turns: Array.from({ length: 5 }, () => f.controller.turnEnd(event, f.ctx)),
    compact: f.controller.compact(f.ctx),
  }).toStrictEqual({
    turns: [
      {
        entries: [
          {
            type: "custom_message",
            customType: "dotfiles:planning-exit:v1",
            content: planExitReminder(f.path()),
            display: false,
          },
        ],
      },
      undefined,
      undefined,
      undefined,
      undefined,
    ],
    compact: attachedPlanContext(f.openPlan("session-one").read()),
  });
  await f.command("");
  f.controller.restore(f.ctx);
  expect(
    f.controller.prompt({ systemPrompt: "Base instructions" }, f.ctx),
  ).toStrictEqual({
    systemPrompt: `Base instructions\n\n${planningPrompt(f.path(), true)}`,
  });
});

it.each(["command", "shortcut"] as const)(
  "reports plan exit once after %s without implying approval",
  async (exit) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Existing plan\n");
    if (exit === "command") {
      await f.command("exit");
    } else {
      f.controller.toggle(f.ctx);
    }
    const expected = {
      message: {
        customType: "dotfiles:planning-exit:v1",
        content: `## Exited Plan Mode\n\nYou have exited plan mode. Plan file: ${f.path()}\nUse the normal file tools to read or update the plan. Follow the user's current request; leaving Plan mode does not itself approve implementation.`,
        display: false,
      },
    };
    expect({
      first: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
      next: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
      projectWrite: await f.call("write", { path: "project.ts" }),
    }).toStrictEqual({
      first: expected,
      next: undefined,
      projectWrite: undefined,
    });
  },
);

it.each([
  { exit: "command", missing: false },
  { exit: "command", missing: true },
  { exit: "shortcut", missing: false },
  { exit: "shortcut", missing: true },
])(
  "reports manual $exit exit accurately (missing draft: $missing)",
  async ({ exit, missing }) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Preserved plan\n");
    if (missing) {
      f.files.contents.delete(f.path());
    }
    f.pi.notifications.splice(0);
    if (exit === "command") {
      await f.command("exit");
    } else {
      f.controller.toggle(f.ctx);
    }
    expect({
      notifications: f.pi.notifications,
      reminder: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
      planExists: f.openPlan("session-one").exists(),
    }).toStrictEqual({
      notifications:
        exit === "command"
          ? [{ message: "Exited plan mode", level: "info" }]
          : [],
      reminder: {
        message: {
          customType: "dotfiles:planning-exit:v1",
          content: planExitReminder(missing ? undefined : f.path()),
          display: false,
        },
      },
      planExists: !missing,
    });
  },
);

it.each(["prompt", "turn-end"] as const)(
  "reports exit through %s when the draft has been deleted",
  async (delivery) => {
    const f = fixture();
    await f.command("");
    f.files.contents.delete(f.path());
    await f.command("exit");
    const deliver = () =>
      delivery === "prompt"
        ? f.controller.prompt({ systemPrompt: "Base" }, f.ctx)
        : f.controller.turnEnd({ outcome: "completed" }, f.ctx);
    const message = {
      customType: "dotfiles:planning-exit:v1",
      content:
        "## Exited Plan Mode\n\nYou have exited plan mode. Follow the user's current request; leaving Plan mode does not itself approve implementation.",
      display: false,
    };
    expect([deliver(), deliver()]).toStrictEqual([
      delivery === "prompt"
        ? { message }
        : { entries: [{ type: "custom_message", ...message }] },
      undefined,
    ]);
  },
);

it("reassesses an existing plan on re-entry and after restoration", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Plan for an earlier task\n");
  const plan = f.openPlan("session-one").read();
  await f.command("exit");
  f.answers.confirm.push(() => true);
  const result = await f.controller.enterTool(f.ctx);
  f.controller.restore(f.ctx);
  const instructions = `${planningPrompt(f.path())}\n\nExisting plan:\nA plan file already exists at ${f.path()}. Read it and compare it with the user's current request.\n- If this is a different task, overwrite the old plan with a new one.\n- If this continues the same task, update the plan and remove obsolete details.\nDo not assume the old plan still applies. Update the plan file before requesting approval.`;
  expect({
    instructions: result.structuredContent?.instructions,
    prompt: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
    plan: f.openPlan("session-one").read(),
  }).toStrictEqual({
    instructions,
    prompt: { systemPrompt: `Base\n\n${planningPrompt(f.path())}` },
    plan,
  });
});

it("preserves an undelivered exit reminder through restart", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Retained plan\n");
  await f.command("exit");
  f.controller.shutdown();
  f.controller.start({ reason: "startup" }, f.ctx);
  expect(f.controller.prompt({ systemPrompt: "Base" }, f.ctx)).toMatchObject({
    message: {
      customType: "dotfiles:planning-exit:v1",
      content: `## Exited Plan Mode\n\nYou have exited plan mode. Plan file: ${f.path()}\nUse the normal file tools to read or update the plan. Follow the user's current request; leaving Plan mode does not itself approve implementation.`,
      display: false,
    },
  });
  f.controller.start({ reason: "reload" }, f.ctx);
  expect(f.controller.prompt({ systemPrompt: "Base" }, f.ctx)).toBeUndefined();
});

it("restores the current plan contents after ordinary-mode compaction", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Initial plan\n");
  await f.command("exit");
  f.controller.prompt({ systemPrompt: "Base" }, f.ctx);
  f.files.replace(f.path(), "# Updated implementation progress\n");
  const plan = f.openPlan("session-one").read();
  expect(f.controller.compact(f.ctx)).toBe(
    `A plan file is attached to this conversation: ${plan.path}\nCurrent revision: ${plan.revision}\n\nPlan contents:\n${plan.content}\nUse this plan if it is relevant to the user's current request and not already complete. This context does not grant implementation approval.`,
  );
});

it.each(["missing", "empty", "unreadable"] as const)(
  "handles a %s attached plan during compaction",
  async (condition) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Plan\n");
    await f.command("exit");
    f.controller.prompt({ systemPrompt: "Base" }, f.ctx);
    f.pi.notifications.splice(0);
    if (condition === "missing") {
      f.files.contents.delete(f.path());
    } else if (condition === "empty") {
      f.files.replace(f.path(), "  \n");
    } else {
      f.files.failures.set(f.path(), new Error("Fixture read failure"));
    }
    expect({
      context: f.controller.compact(f.ctx),
      notifications: f.pi.notifications,
      conversation: f.pi.conversation,
    }).toStrictEqual({
      context: undefined,
      notifications:
        condition === "unreadable"
          ? [
              {
                message:
                  "Cannot restore plan context: Error: Fixture read failure",
                level: "warning",
              },
            ]
          : [],
      conversation: [],
    });
  },
);

it.each(["aborted", "error"] as const)(
  "keeps the exit notice pending after a %s turn",
  async (outcome) => {
    const f = fixture();
    await f.command("");
    await f.command("exit");
    expect(f.controller.turnEnd({ outcome }, f.ctx)).toBeUndefined();
    expect(f.controller.prompt({ systemPrompt: "Base" }, f.ctx)).toStrictEqual({
      message: {
        customType: "dotfiles:planning-exit:v1",
        content: planExitReminder(),
        display: false,
      },
    });
    expect(
      f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
    ).toBeUndefined();
  },
);

it.each(["current", "clear", "revise", "cancel"] as const)(
  "does not use transient notifications for a %s review outcome",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Plan\n");
    f.pi.notifications.splice(0);
    f.reviews.push({
      decision,
      presentedPlan: f.openPlan("session-one").read(),
    });
    await f.execute("submit_plan");
    expect(f.pi.notifications).toStrictEqual([]);
  },
);

it("offers same-session context clearing during approval", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Approved plan\n");
  f.answers.select.push(() => "Yes, clear context");
  expect((await f.execute("submit_plan")).details).toMatchObject({
    decision: "clear",
  });
});

it.each([
  "rm file",
  "git diff --stat",
  "python3 investigate.py",
  "printf x > output",
])("leaves native bash policy and arguments unchanged: %s", async (command) => {
  const f = fixture();
  await f.command("");
  const input = { command, timeout: 7 };
  expect({
    parent: await f.call("bash", input),
    child: researchPolicy({ toolName: "bash", input }),
    input,
    dialogs: f.pi.dialogs,
  }).toStrictEqual({
    parent: undefined,
    child: undefined,
    input: { command, timeout: 7 },
    dialogs: [],
  });
});

it.each([
  "mcp__new_server__inspect",
  "mcp__fixture__mutate_tool",
  "tool_search",
  "list_mcp_resources",
  "list_mcp_resource_templates",
  "read_mcp_resource",
])(
  "delegates %s to normal native exposure and permissions",
  async (toolName) => {
    const f = fixture();
    await f.command("");
    const input = { server: "unlisted", arguments: { action: "inspect" } };
    expect({
      parent: await f.call(toolName, input),
      child: researchPolicy({ toolName, input }),
      input,
    }).toStrictEqual({
      parent: undefined,
      child: undefined,
      input: { server: "unlisted", arguments: { action: "inspect" } },
    });
  },
);

it("restricts ordinary file and preview mutations while preserving plan edits", async () => {
  const f = fixture();
  await f.command("");
  expect(
    await f.call("write", { path: f.path(), content: "plan" }),
  ).toBeUndefined();
  expect(await f.call("edit", { path: "src/file.ts" })).toMatchObject({
    block: true,
  });
  expect(
    await f.call("apply_patch", {
      patch: "project mutation",
      parentToolCallId: "codemode",
    }),
  ).toMatchObject({ block: true });
  expect(
    await f.call("ask_user", { question: "Requirement?" }),
  ).toBeUndefined();
  expect(await f.call("subagent", { agent: "worker" })).toMatchObject({
    block: true,
  });
  expect(await f.call("edit", { path: "src/file.ts" })).toMatchObject({
    block: true,
  });
});

it.each([undefined, "No, keep planning"])(
  "keeps planning after an unapproved review: %s",
  async (choice) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Real plan\nImplement a change.\n");
    f.answers.select.push(() => choice);
    await f.execute("submit_plan");
    expect(await f.call("write", { path: "implementation.ts" })).toMatchObject({
      block: true,
    });
  },
);

it("rejects approval when the file changes during review, then accepts the reviewed revision", async () => {
  const f = fixture();
  await f.command("");
  const path = f.path();
  f.files.replace(path, "# First plan\n");
  f.answers.select.push(async () => {
    f.files.replace(path, "# Changed plan\n");
    return "Yes, keep context";
  });
  await expect(f.execute("submit_plan")).rejects.toThrow(
    "changed during review",
  );
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  f.answers.select.push(() => "Yes, keep context");
  await f.execute("submit_plan");
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  await f.completeApproval();
  expect(await f.call("write", { path: "project.ts" })).toBeUndefined();
});

it.each(["current", "clear"] as const)(
  "binds %s approval to the refreshed plan snapshot",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Initial plan\n");
    f.reviews.push(async (request) => {
      f.files.replace(
        f.path(),
        "# Edited plan\n\nImplement the updated approach.\n",
      );
      const presentedPlan = request.read();
      request.present(presentedPlan);
      return { decision, presentedPlan };
    });
    const partialResults: PlanningResult[] = [];
    const result = await f.controller.submit(f.ctx, undefined, (update) => {
      partialResults.push(update);
    });
    const presentedPlan = f.openPlan("session-one").read();
    expect({
      details: result.details,
      partialResults,
    }).toStrictEqual({
      details: {
        formatVersion: 1,
        decision,
        path: presentedPlan.path,
        revision: presentedPlan.revision,
        presentedPlan,
        reviewSummary:
          decision === "current"
            ? "Plan approved. Finish this planning turn and wait for the implementation transition; do not edit project files yet."
            : "Plan approved. Wait for context clearing; keep this conversation in planning until the transition finishes.",
      },
      partialResults: [
        {
          content: [{ type: "text", text: "Review the presented plan." }],
          details: { decision: "pending", presentedPlan },
        },
      ],
    });
  },
);

it.each(["current", "revise", "cancel"] as const)(
  "delivers manual plan edits to the model after a %s review",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Initial plan\n");
    f.reviews.push(async (request) => {
      f.files.replace(f.path(), "# Edited plan\n\nKeep the user changes.\n");
      const presentedPlan = request.read();
      request.present(presentedPlan);
      return { decision, presentedPlan };
    });
    const result = await f.execute("submit_plan");
    const plan = f.openPlan("session-one").read();
    const summaries = {
      current:
        "Plan approved. Finish this planning turn and wait for the implementation transition; do not edit project files yet.",
      revise:
        "The user requested revisions. Continue planning and ask for the necessary feedback.",
      cancel:
        "Plan review was cancelled. Continue planning; implementation has not been approved.",
    };
    expect(result.content).toStrictEqual([
      { type: "text", text: summaries[decision] },
      {
        type: "text",
        text: `Reviewed plan:
Plan file: ${plan.path}
Reviewed revision: ${plan.revision}

${plan.content}`,
      },
    ]);
  },
);

it.each(["# Unchanged plan\n", "# Externally revised plan\n"])(
  "returns the full approved plan to the model: %s",
  async (content) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), content);
    f.answers.select.push(() => "Yes, keep context");
    const result = await f.execute("submit_plan");
    const plan = f.openPlan("session-one").read();
    expect(result.content).toStrictEqual([
      {
        type: "text",
        text: "Plan approved. Finish this planning turn and wait for the implementation transition; do not edit project files yet.",
      },
      {
        type: "text",
        text: `Reviewed plan:\nPlan file: ${plan.path}\nReviewed revision: ${plan.revision}\n\n${plan.content}`,
      },
    ]);
  },
);

it.each(["current", "clear", "revise"] as const)(
  "delivers feedback with a %s decision, including after context clearing",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    const plan = f.openPlan("session-one").read();
    const feedback = "Preserve the existing command-line interface.";
    f.reviews.push({ decision, presentedPlan: plan, feedback });
    const messages = {
      current:
        "Plan approved. Finish this planning turn and wait for the implementation transition; do not edit project files yet.",
      clear:
        "Plan approved. Wait for context clearing; keep this conversation in planning until the transition finishes.",
      revise:
        "The user requested revisions. Continue planning and incorporate their feedback.",
    };
    expect({
      result: await f.execute("submit_plan"),
      boundary: await f.prepareClear({ outcome: "completed" }, f.ctx),
    }).toStrictEqual({
      result: {
        content: [
          { type: "text", text: messages[decision] },
          ...(decision === "current"
            ? [
                {
                  type: "text",
                  text: `Reviewed plan:\nPlan file: ${plan.path}\nReviewed revision: ${plan.revision}\n\n${plan.content}`,
                },
              ]
            : []),
          { type: "text", text: `User feedback:\n${feedback}` },
        ],
        details: {
          formatVersion: 1,
          decision,
          path: plan.path,
          revision: plan.revision,
          presentedPlan: plan,
          reviewSummary: messages[decision],
          feedback,
        },
        structuredContent: {
          version: 1,
          decision,
          plan,
          imageCount: 0,
          feedback,
        },
      },
      boundary:
        decision === "clear"
          ? {
              entries: [
                {
                  type: "compaction",
                  summary: `${implementationContext(plan, "/fixture/session.jsonl")}\n\nUser feedback:\n${feedback}`,
                  firstKeptEntryId: null,
                  details: {
                    customType: "dotfiles:planning-clear:v1",
                    token: "ticket-1",
                  },
                },
              ],
            }
          : undefined,
    });
  },
);

it.each([
  { label: "Yes, keep context", decision: "current" },
  { label: "Yes, clear context", decision: "clear" },
  { label: "No, keep planning", decision: "revise" },
])(
  "collects a comment with the RPC $decision choice",
  async ({ label, decision }) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Plan\n");
    f.answers.select.push(
      () => "Add a comment",
      () => label,
    );
    f.answers.input.push(() => "Keep compatibility.");
    const plan = f.openPlan("session-one").read();
    const result = await f.review(f.ctx, {
      plan,
      signal: f.run.signal,
      read: () => plan,
      present: () => {},
    });
    expect(result).toStrictEqual({
      decision,
      presentedPlan: plan,
      feedback: "Keep compatibility.",
    });
  },
);

it("uses the refreshed snapshot when clearing context", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Initial plan\n");
  f.reviews.push(async (request) => {
    f.files.replace(f.path(), "# Edited plan\n");
    const presentedPlan = request.read();
    request.present(presentedPlan);
    return { decision: "clear", presentedPlan };
  });
  await f.execute("submit_plan");
  const plan = f.openPlan("session-one").read();
  expect(await f.prepareClear({ outcome: "completed" }, f.ctx)).toStrictEqual({
    entries: [
      {
        type: "compaction",
        summary: implementationContext(plan, "/fixture/session.jsonl"),
        firstKeptEntryId: null,
        details: {
          customType: "dotfiles:planning-clear:v1",
          token: "ticket-1",
        },
      },
    ],
  });
});

it("rejects another file change after the edited snapshot was presented", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Initial plan\n");
  f.reviews.push(async (request) => {
    f.files.replace(f.path(), "# Edited plan\n");
    const presentedPlan = request.read();
    request.present(presentedPlan);
    f.files.replace(f.path(), "# Later external edit\n");
    return { decision: "current", presentedPlan };
  });
  await expect(f.execute("submit_plan")).rejects.toThrow(
    "changed during review",
  );
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
});

it("cancels review without granting implementation authority", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Plan\n");
  const answer = Promise.withResolvers<string | undefined>();
  f.answers.select.push(() => answer.promise);
  const abort = new AbortController();
  const pending = f.execute("submit_plan", {}, abort.signal);
  abort.abort();
  answer.resolve("Yes, keep context");
  await pending;
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
});

it.each(["current", "clear"] as const)(
  "starts implementation once after verified %s settlement without an exit reminder",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    f.reviews.push({
      decision,
      presentedPlan: f.openPlan("session-one").read(),
    });
    await f.execute("submit_plan");
    const boundary = await f.prepareClear({ outcome: "completed" }, f.ctx);
    const beforeSettlement = {
      projectWrite: (await f.call("write", { path: "project.ts" }))?.block,
      reviewAvailable: f.pi.reviewAvailable,
    };
    f.commit(boundary);
    f.controller.settled({ aborted: false }, f.ctx);
    f.controller.settled({ aborted: false }, f.ctx);
    const plan = f.openPlan("session-one").read();
    expect({
      beforeSettlement,
      conversation: f.pi.conversation,
      sessionId: f.ctx.sessionManager.getSessionId(),
      plan,
      projectWrite: await f.call("write", { path: "project.ts" }),
      prompt: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
      reviewAvailable: f.pi.reviewAvailable,
    }).toStrictEqual({
      beforeSettlement: { projectWrite: true, reviewAvailable: true },
      conversation: [
        {
          kind: "implementation",
          content: implementationContext(plan, "/fixture/session.jsonl"),
        },
      ],
      sessionId: "session-one",
      plan: {
        path: f.path(),
        revision: plan.revision,
        content: "# Approved plan\n",
      },
      projectWrite: undefined,
      prompt: undefined,
      reviewAvailable: false,
    });
  },
);

it.each(
  (["current", "clear"] as const).flatMap((decision) =>
    (["completed", "error", "aborted"] as const).map((outcome) => ({
      decision,
      outcome,
    })),
  ),
)(
  "rejects $outcome after proposing $decision settlement without fresh verification",
  async ({ decision, outcome }) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    f.reviews.push({
      decision,
      presentedPlan: f.openPlan("session-one").read(),
    });
    await f.execute("submit_plan");
    f.commit(await f.prepareClear({ outcome: "completed" }, f.ctx));
    f.controller.beforeSettle({ outcome }, f.ctx);
    f.controller.settled({ aborted: false }, f.ctx);
    expect(f.pi.conversation).toStrictEqual([]);
  },
);

it.each([
  { decision: "current", when: "before" },
  { decision: "current", when: "after" },
  { decision: "clear", when: "before" },
  { decision: "clear", when: "after" },
] as const)(
  "rejects a changed plan $when $decision settlement",
  async ({ decision, when }) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    f.reviews.push({
      decision,
      presentedPlan: f.openPlan("session-one").read(),
    });
    await f.execute("submit_plan");
    if (when === "before") {
      f.files.replace(f.path(), "# External change\n");
    }
    const boundary = await f.prepareClear({ outcome: "completed" }, f.ctx);
    f.commit(boundary);
    if (when === "after") {
      f.files.replace(f.path(), "# External change\n");
    }
    f.controller.settled({ aborted: false }, f.ctx);
    expect(f.pi.conversation).toStrictEqual([]);
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
  },
);

it.each(["aborted", "error"] as const)(
  "does not clear context after a %s run",
  async (outcome) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    f.answers.select.push(() => "Yes, clear context");
    await f.execute("submit_plan");
    expect(await f.prepareClear({ outcome }, f.ctx)).toBeUndefined();
    f.controller.settled({ aborted: outcome === "aborted" }, f.ctx);
    expect(f.pi.conversation).toStrictEqual([]);
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
  },
);

it.each(["current", "clear"] as const)(
  "revokes pending %s approval on new user input",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    f.reviews.push({
      decision,
      presentedPlan: f.openPlan("session-one").read(),
    });
    await f.execute("submit_plan");
    await f.controller.verifyClear(f.ctx);
    f.controller.input();
    const boundary = f.controller.beforeSettle({ outcome: "completed" }, f.ctx);
    f.commit(boundary);
    f.controller.settled({ aborted: false }, f.ctx);
    expect({
      boundary,
      conversation: f.pi.conversation,
      projectWrite: await f.call("write", { path: "project.ts" }),
    }).toStrictEqual({
      boundary: undefined,
      conversation: [],
      projectWrite: {
        block: true,
        reason: `Only the active plan may be edited: ${f.path()}`,
      },
    });
  },
);

it("restores planning through reload and compaction without replaying a model prompt", async () => {
  const f = fixture();
  await f.command("");
  const path = f.path();
  f.files.replace(path, "# Durable plan\n");
  f.controller.start({ reason: "reload" }, f.ctx);
  const reloaded = f.pi.reviewAvailable;
  f.controller.compact(f.ctx);
  expect({ reloaded, compacted: f.pi.reviewAvailable }).toStrictEqual({
    reloaded: true,
    compacted: true,
  });
  expect(f.path()).toBe(path);
  expect(f.files.read(path)).toBe("# Durable plan\n");
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  expect(f.pi.conversation).toStrictEqual([]);
});

it.each([false, true])(
  "forks the edited intermediate plan with reload=%s",
  async (reload) => {
    const f = fixture();
    await f.command("");
    const original = f.path();
    f.files.replace(original, "# Original plan\n");

    f.session.id = "first-fork";
    f.controller.start({ reason: "fork" }, f.ctx);
    const first = f.openPlan("first-fork");
    f.files.replace(first.path, "# Edited fork plan\n");

    if (reload) {
      f.controller.start({ reason: "reload" }, f.ctx);
    }

    f.session.id = "nested-fork";
    f.controller.start({ reason: "fork" }, f.ctx);
    const nested = f.openPlan("nested-fork");
    expect({
      original: f.files.read(original),
      first: first.read().content,
      nested: nested.read().content,
    }).toStrictEqual({
      original: "# Original plan\n",
      first: "# Edited fork plan\n",
      nested: "# Edited fork plan\n",
    });
    expect(f.pi.conversation).toStrictEqual([]);
  },
);

it.each([false, true])(
  "copies inactive forks without enabling plan mode (existing draft: %s)",
  async (hasDraft) => {
    const f = fixture(
      [
        {
          type: "custom",
          customType: stateEntry,
          data: { version: 1, active: false, sourceSessionId: "session-one" },
        },
      ],
      "first-fork",
      (open) => {
        if (hasDraft) {
          open("session-one").write("# Inactive plan\n");
        }
      },
    );
    const original = f.openPlan("session-one");
    const first = f.openPlan("first-fork");
    expect(f.files.read(first.path)).toBe(
      hasDraft ? "# Inactive plan\n" : undefined,
    );
    f.files.replace(first.path, "# Edited inactive plan\n");

    f.session.id = "nested-fork";
    f.controller.start({ reason: "fork" }, f.ctx);
    const nested = f.openPlan("nested-fork");

    expect({
      original: original.exists() ? original.read().content : null,
      first: first.read().content,
      nested: nested.read().content,
      research: f.pi.research,
      projectWrite: await f.call("write", { path: "project.ts" }),
    }).toStrictEqual({
      original: hasDraft ? "# Inactive plan\n" : null,
      first: "# Edited inactive plan\n",
      nested: "# Edited inactive plan\n",
      research: [],
      projectWrite: undefined,
    });
  },
);

it("announces an inactive fork's own plan path even when the source exit was already reported", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Shared history\n");
  await f.command("exit");
  f.controller.prompt({ systemPrompt: "Base" }, f.ctx);
  f.session.id = "inactive-fork";
  f.controller.start({ reason: "fork" }, f.ctx);
  expect(f.controller.prompt({ systemPrompt: "Base" }, f.ctx)).toStrictEqual({
    message: {
      customType: "dotfiles:planning-exit:v1",
      content: planExitReminder(f.path()),
      display: false,
    },
  });
  expect(f.controller.prompt({ systemPrompt: "Base" }, f.ctx)).toBeUndefined();
  expect(f.pi.conversation).toStrictEqual([]);
});

it.each(["resume", "reload", "fork"])(
  "requests a replacement draft after %s restores a missing plan",
  async (reason) => {
    const id = reason === "fork" ? "session-fork" : "session-one";
    const f = fixture(
      [
        {
          type: "custom",
          customType: stateEntry,
          data: { version: 1, active: true, sourceSessionId: "session-one" },
        },
      ],
      id,
    );
    f.controller.start({ reason }, f.ctx);
    const path = f.openPlan(id).path;

    await expect(f.execute("submit_plan")).rejects.toThrow(
      `Write a new implementation plan to ${path} before requesting approval.`,
    );
    const missingPlanDialogs = [...f.pi.dialogs];
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
    expect(
      await f.call("write", { path, content: "# Replacement plan\n" }),
    ).toBeUndefined();

    f.files.replace(path, "# Replacement plan\n");
    f.answers.select.push(() => "Yes, keep context");
    await f.execute("submit_plan");
    expect({
      missingPlanDialogs,
      replacementDialogs: f.pi.dialogs.map(({ kind, state }) => ({
        kind,
        state,
      })),
    }).toStrictEqual({
      missingPlanDialogs: [],
      replacementDialogs: [{ kind: "select", state: "answered" }],
    });
    await f.completeApproval();
    expect(await f.call("write", { path: "project.ts" })).toBeUndefined();
  },
);

it("blocks model approval while subagents are active but permits human exit", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Plan\n\nImplement the requested change.\n");
  f.pi.activeSubagents = 1;
  await expect(f.execute("submit_plan")).rejects.toThrow(activeSubagent);
  const beforeExit = (await f.call("write", { path: "project.ts" }))?.block;
  await f.command("exit");
  expect({
    dialogs: f.pi.dialogs,
    beforeExit,
    afterExit: await f.call("write", { path: "project.ts" }),
  }).toStrictEqual({
    dialogs: [],
    beforeExit: true,
    afterExit: undefined,
  });
});

it.each([
  ["web_enable", {}],
  ["pi_lens_activate_tools", { tools: ["ast_grep_search", "lsp_navigation"] }],
  ["lsp_navigation", { operation: "definition" }],
  ["lsp_navigation", { operation: "rename", apply: false }],
  ["lsp_navigation", { operation: "executeCommand", apply: false }],
  ["ast_grep_replace", { apply: false }],
  ["todo", { action: "list" }],
  ["bg_wait", {}],
  ["subagent", { action: "status", id: "run" }],
  ["subagent", { action: "guide", options: { topic: "tool-reference" } }],
  ["subagent", { action: "stop", id: "run" }],
] satisfies [string, Record<string, unknown>][])(
  "permits research through %s in the parent and child",
  async (toolName, input) => {
    const f = fixture();
    await f.command("");
    expect({
      parent: await f.call(toolName, input),
      child: researchPolicy({ toolName, input }),
    }).toStrictEqual({ parent: undefined, child: undefined });
  },
);

it.each([
  ["lsp_navigation", { operation: "rename", apply: true }],
  ["lsp_navigation", { operation: "rename_file", apply: true }],
  ["lsp_navigation", { operation: "executeCommand", apply: true }],
  ["lsp_navigation", { operation: "unknown" }],
  ["ast_grep_replace", { apply: true }],
] satisfies [string, Record<string, unknown>][])(
  "blocks mutations and unknown operations through %s",
  async (toolName, input) => {
    const f = fixture();
    await f.command("");
    expect({
      parent: (await f.call(toolName, input))?.block,
      child: researchPolicy({ toolName, input })?.block,
    }).toStrictEqual({ parent: true, child: true });
  },
);

it.each([undefined, true, false])(
  "permits native planning delegation with async:%s in the parent and child",
  async (async) => {
    const f = fixture();
    await f.command("");
    const input = {
      agent: "planning-explore",
      task: "Inspect the API.",
      ...(async === undefined ? {} : { async }),
    };
    expect({
      parent: await f.call("subagent", input),
      child: researchPolicy({ toolName: "subagent", input }),
      input,
    }).toStrictEqual({
      parent: undefined,
      child: undefined,
      input: {
        agent: "planning-explore",
        task: "Inspect the API.",
        ...(async === undefined ? {} : { async }),
        output: false,
        options: { context: "fresh", artifacts: false, mission: false },
      },
    });
  },
);

it.each([
  { agent: "worker", task: "Change the project." },
  { agent: "planning-explore", task: "Inspect.", output: "project.ts" },
  { agent: "planning-explore", task: "Inspect.", worktree: true },
  { agent: "planning-explore", task: "Inspect.", options: { context: "fork" } },
  {
    agent: "planning-explore",
    task: "Inspect.",
    options: { gate: "touch project.ts" },
  },
  { agent: "planning-explore", task: "Inspect.", options: { sessionDir: "." } },
  { workflow: "run-ci", args: { command: "touch project.ts" } },
  { action: "create", config: { name: "worker" } },
])("rejects unsafe research delegation: %j", async (input) => {
  const f = fixture();
  await f.command("");
  expect({
    parent: (await f.call("subagent", input))?.block,
    child: researchPolicy({ toolName: "subagent", input })?.block,
  }).toStrictEqual({ parent: true, child: true });
});

it.each(["ask_user", "submit_plan", "enter_plan_mode", "write", "edit"])(
  "blocks %s in a research child",
  (toolName) => {
    expect(researchPolicy({ toolName, input: {} })).toStrictEqual({
      block: true,
      reason:
        "Research agents cannot edit files, ask the user or approve implementation.",
    });
  },
);
it.each(["revise", "exit"])(
  "invalidates an older clear-context approval on %s",
  async (action) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Plan\n");
    f.answers.select.push(() => "Yes, clear context");
    await f.execute("submit_plan");
    if (action === "revise") {
      f.answers.select.push(() => "No, keep planning");
      await f.execute("submit_plan");
    } else {
      await f.command("exit");
      await f.command("");
    }
    f.controller.settled({ aborted: false }, f.ctx);
    expect(f.pi.conversation).toStrictEqual([]);
  },
);

it.each([
  "not committed",
  "modified",
  "aborted",
  "keeps history",
  "superseded",
] as const)(
  "keeps implementation blocked when native clearing is %s",
  async (failure) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    f.answers.select.push(() => "Yes, clear context");
    await f.execute("submit_plan");
    const boundary = await f.prepareClear({ outcome: "completed" }, f.ctx);
    if (failure !== "not committed") {
      const entries = boundary?.entries ?? [];
      if (failure === "modified") {
        const entry = entries[0];
        if (entry?.type !== "compaction") {
          throw new Error("Expected a compaction proposal");
        }
        entry.summary = "Different context";
      }
      if (failure === "keeps history") {
        const entry = entries[0];
        if (entry?.type !== "compaction") {
          throw new Error("Expected a compaction proposal");
        }
        entry.firstKeptEntryId = "earlier-entry";
      }
      f.commit(boundary);
      if (failure === "superseded") {
        f.branch.push({
          type: "compaction",
          id: "later",
          firstKeptEntryId: "later",
          summary: "Other context",
        });
      }
    }
    f.controller.settled({ aborted: failure === "aborted" }, f.ctx);
    expect(f.pi.conversation).toStrictEqual([]);
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
  },
);

it("rechecks native jobs before clearing the approved context", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Approved plan\n");
  f.answers.select.push(() => "Yes, clear context");
  await f.execute("submit_plan");
  f.pi.activeSubagents = 1;
  expect(await f.prepareClear({ outcome: "completed" }, f.ctx)).toBeUndefined();
  f.controller.settled({ aborted: false }, f.ctx);
  expect(f.pi.conversation).toStrictEqual([]);
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
});

it.each([
  "unverified",
  "missing signal",
  "aborted signal",
  "failed recheck",
] as const)(
  "keeps context intact when final verification is %s",
  async (failure) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    f.answers.select.push(() => "Yes, clear context");
    await f.execute("submit_plan");
    if (failure === "missing signal") {
      delete f.ctx.signal;
    }
    if (failure !== "unverified") {
      await f.controller.verifyClear(f.ctx);
    }
    if (failure === "aborted signal") {
      f.run.abort();
    }
    if (failure === "failed recheck") {
      f.pi.activeSubagents = 1;
      await f.controller.verifyClear(f.ctx);
    }
    expect(
      f.controller.beforeSettle({ outcome: "completed" }, f.ctx),
    ).toBeUndefined();
    f.controller.settled({ aborted: false }, f.ctx);
    expect(f.pi.conversation).toStrictEqual([]);
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
  },
);

it("keeps the live session usable when restoring its replacement fails", async () => {
  const f = fixture();
  await f.command("");
  f.files.directoryFailure = new Error("fixture restore failure");

  expect(() => f.controller.restore(f.ctx)).toThrow("fixture restore failure");
  f.files.directoryFailure = undefined;
  expect(f.pi.research).toStrictEqual(["session-one"]);
  await expect(
    f.call("write", { path: f.path(), content: "draft" }),
  ).resolves.toBeUndefined();
});

it("rejects entry when research configuration cannot be loaded", async () => {
  const f = fixture();
  f.pi.researchFailure = new Error("Invalid planning.json");

  await expect(f.command("")).rejects.toThrow("Invalid planning.json");
  expect({
    saved: f.branch,
    draftExists: f.openPlan("session-one").exists(),
    projectWrite: await f.call("write", { path: "project.ts" }),
  }).toStrictEqual({ saved: [], draftExists: false, projectWrite: undefined });
});

it.each([true, false])(
  "preserves draft lineage through compaction (active: %s)",
  async (active) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Compacted draft");
    if (!active) {
      await f.command("exit");
    }
    f.branch.splice(0);
    f.controller.compact(f.ctx);
    f.session.id = "compacted-fork";
    f.controller.start({ reason: "fork" }, f.ctx);

    expect({
      draft: f.files.read(f.path()),
      active: f.branch.at(-1),
    }).toStrictEqual({
      draft: "# Compacted draft",
      active: {
        type: "custom",
        customType: stateEntry,
        data: {
          version: 1,
          active,
          sourceSessionId: "compacted-fork",
          exitReminderPending: !active,
        },
      },
    });
  },
);

it("restores branch policy after tree navigation within the same conversation", async () => {
  const f = fixture();
  await f.command("");
  f.branch.splice(0);
  f.controller.restore(f.ctx);

  expect({
    projectWrite: await f.call("write", { path: "project.ts" }),
    research: f.pi.research,
  }).toStrictEqual({ projectWrite: undefined, research: [] });
});
