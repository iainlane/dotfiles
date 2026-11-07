import type { BoundaryResult } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import {
  createPlanning,
  type PlanningContext,
  type PlanningDependencies,
  type PlanningResult,
} from "../src/controller.ts";
import { childPolicy } from "../src/child.ts";
import type { PlanEditor } from "../src/editor.ts";
import {
  attachedPlanContext,
  enterPlanDescription,
  implementationContext,
  planExitReminder,
  planningPrompt,
} from "../src/prompt.ts";
import { reviewPlan } from "../src/review.ts";
import { stateEntry } from "../src/session.ts";
import { outcomeEntryType } from "../src/outcomes.ts";
import { PlanStore } from "../src/store.ts";
import { MemoryFiles } from "./memory-files.ts";
import { feedbackImage } from "./fixtures/image.ts";

const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) {
    cleanup();
  }
});

function fixture(
  branch: unknown[] = [],
  initialId = "session-one",
  seed?: (open: (id: string) => PlanStore) => void,
) {
  const directory = "/planning-fixture";
  const files = new MemoryFiles();
  const openPlan = (id: string) =>
    new PlanStore(`${directory}/plans`, id, files);
  const disposed = vi.fn<() => void>();
  const configure = vi.fn<PlanningDependencies["configure"]>(() => [disposed]);
  const sendUserMessage = vi.fn<PlanningDependencies["sendUserMessage"]>();
  const presentPlan = vi.fn<PlanningDependencies["presentPlan"]>();
  const outcomes = vi.fn<PlanningDependencies["recordOutcome"]>();
  const editor = {
    name: "fixture-editor",
    open: vi.fn<PlanEditor["open"]>(async () => {}),
  } satisfies PlanEditor;
  const sendImplementationMessage =
    vi.fn<
      (
        content: Parameters<
          PlanningDependencies["sendImplementationMessage"]
        >[0],
      ) => void
    >();
  const select = vi.fn<PlanningContext["ui"]["select"]>();
  const confirm = vi.fn<PlanningContext["ui"]["confirm"]>();
  const run = new AbortController();
  const ctx: PlanningContext = {
    signal: run.signal,
    cwd: directory,
    mode: "rpc",
    hasUI: true,
    model: { input: ["text", "image"] },
    sessionManager: {
      getSessionId: () => initialId,
      getBranch: () => branch,
      getSessionFile: () => "/fixture/session.jsonl",
    },
    ui: {
      notify: vi.fn<PlanningContext["ui"]["notify"]>(),
      setStatus: vi.fn<PlanningContext["ui"]["setStatus"]>(),
      select,
      input: vi.fn<PlanningContext["ui"]["input"]>(),
      confirm,
      getToolsExpanded: () => false,
      setToolsExpanded: () => {},
      custom: async () => ({
        decision: "cancel",
        presentedPlan: { path: "", revision: "", content: "" },
      }),
    },
  };
  let identity = 0;
  const ensureSubagentsIdle = vi.fn<(signal: AbortSignal) => Promise<void>>(
    async () => {},
  );
  const review = vi.fn<PlanningDependencies["review"]>((context, request) =>
    reviewPlan(context, request, { name: "nvim", open: async () => {} }),
  );
  const startInPlan = vi.fn<PlanningDependencies["startInPlan"]>(() => false);
  const setReviewAvailable =
    vi.fn<PlanningDependencies["setReviewAvailable"]>();
  const publishStatus =
    vi.fn<NonNullable<PlanningDependencies["publishStatus"]>>();
  const controller = createPlanning({
    openPlan,
    configure,
    publishStatus,
    presentPlan,
    sendUserMessage,
    sendImplementationMessage: (content) => sendImplementationMessage(content),
    recordOutcome: outcomes,
    recordSavedState: (data) => {
      branch.push({ type: "custom", customType: stateEntry, data });
    },
    ensureSubagentsIdle,
    startInPlan,
    setReviewAvailable,
    requestId: () => `ticket-${++identity}`,
    review,
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
    publishStatus,
    select,
    confirm,
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
    presentPlan,
    outcomes,
    editor,
    disposed,
    configure,
    sendUserMessage,
    sendImplementationMessage,
    files,
    openPlan,
    ensureSubagentsIdle,
    startInPlan,
    setReviewAvailable,
    review,
    commit,
    completeApproval: async () => {
      commit(await prepareClear({ outcome: "completed" }, ctx));
      controller.settled({ aborted: false }, ctx);
    },
  };
}

it("publishes semantic active state alongside the standalone native fallback", async () => {
  const h = fixture();
  expect(h.publishStatus).toHaveBeenLastCalledWith({
    sessionId: "session-one",
    active: false,
  });
  await h.command("");
  expect(h.publishStatus).toHaveBeenLastCalledWith({
    sessionId: "session-one",
    active: true,
  });
  expect(h.ctx.ui.setStatus).toHaveBeenLastCalledWith(
    "planning",
    "plan mode on",
  );
  await h.command("exit");
  expect(h.publishStatus).toHaveBeenLastCalledWith({
    sessionId: "session-one",
    active: false,
  });
  expect(h.ctx.ui.setStatus).toHaveBeenLastCalledWith("planning", undefined);
  h.controller.restore({
    ...h.ctx,
    sessionManager: {
      ...h.ctx.sessionManager,
      getSessionId: () => "session-two",
      getBranch: () => [],
    },
  });
  expect(h.publishStatus).toHaveBeenLastCalledWith({
    sessionId: "session-two",
    active: false,
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
      reviewed: f.review.mock.calls.map(([, request]) => request.plan.content),
    }).toStrictEqual({ decision: "cancel", reviewed: [content] });
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
      reviews: f.review.mock.calls,
      implementation: f.sendImplementationMessage.mock.calls,
    }).toStrictEqual({ reviews: [], implementation: [] });
  },
);

it.each(["current", "clear", "revise", "cancel"] as const)(
  "returns genuine structured output for a %s review",
  async (decision) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Context\nImplement the requested change.\n");
    const plan = f.openPlan("session-one").read();
    f.review.mockResolvedValueOnce({
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
    f.review.mockResolvedValueOnce({
      decision,
      presentedPlan: plan,
      feedback: "Keep the API.",
      images: [feedbackImage],
    });
    await f.execute("submit_plan");
    expect(f.outcomes.mock.calls).toStrictEqual([
      [
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
      ],
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
    f.review.mockResolvedValueOnce({
      decision: "current",
      presentedPlan: plan,
      images: [feedbackImage],
    });
    await expect(f.execute("submit_plan")).rejects.toThrow(
      "image-capable model",
    );
    await f.completeApproval();
    expect({
      outcomes: f.outcomes.mock.calls,
      implementation: f.sendImplementationMessage.mock.calls,
    }).toStrictEqual({ outcomes: [], implementation: [] });
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
    f.review.mockResolvedValueOnce({
      decision: "current",
      presentedPlan: f.openPlan("session-one").read(),
      feedback,
    });
    await expect(f.execute("submit_plan")).rejects.toThrow(message);
    await f.completeApproval();
    expect({
      outcomes: f.outcomes.mock.calls,
      sends: f.sendImplementationMessage.mock.calls,
    }).toStrictEqual({ outcomes: [], sends: [] });
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
    sends: f.sendImplementationMessage.mock.calls,
    guarded: (await f.call("write", { path: "project.ts" }))?.block,
  }).toStrictEqual({ sends: [], guarded: true });
});

it("does not start image-based implementation after the model loses image support", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  f.review.mockResolvedValueOnce({
    decision: "current",
    presentedPlan: f.openPlan("session-one").read(),
    images: [feedbackImage],
  });
  await f.execute("submit_plan");
  f.ctx.model = { input: ["text"] };
  await expect(f.completeApproval()).rejects.toThrow("image-capable model");
  f.controller.settled({ aborted: false }, f.ctx);
  expect({
    sends: f.sendImplementationMessage.mock.calls,
    guarded: (await f.call("write", { path: "project.ts" }))?.block,
  }).toStrictEqual({ sends: [], guarded: true });
});

it("does not grant implementation when the outcome cannot be persisted", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  const plan = f.openPlan("session-one").read();
  f.review.mockResolvedValueOnce({ decision: "current", presentedPlan: plan });
  f.outcomes.mockImplementationOnce(() => {
    throw new Error("Journal unavailable");
  });
  await expect(f.execute("submit_plan")).rejects.toThrow("Journal unavailable");
  await f.completeApproval();
  expect(f.sendImplementationMessage.mock.calls).toStrictEqual([]);
});

it.each([
  {
    stage: "verification",
    decision: "current",
    reason: "Error: Research restarted",
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
    f.review.mockResolvedValueOnce({ decision, presentedPlan: plan });
    await f.execute("submit_plan");
    if (stage === "verification") {
      f.ensureSubagentsIdle.mockRejectedValueOnce(
        new Error("Research restarted"),
      );
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
      outcomes: f.outcomes.mock.calls,
      sends: f.sendImplementationMessage.mock.calls,
    }).toStrictEqual({
      outcomes: [
        [
          {
            version: 1,
            event: "review",
            decision,
            path: plan.path,
            revision: plan.revision,
          },
        ],
        [
          {
            version: 1,
            event: "implementation-failed",
            path: plan.path,
            revision: plan.revision,
            reason,
          },
        ],
      ],
      sends: [],
    });
  },
);

it("records a failed implementation launch and never retries the consumed approval", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  const plan = f.openPlan("session-one").read();
  f.review.mockResolvedValueOnce({ decision: "current", presentedPlan: plan });
  f.sendImplementationMessage.mockImplementationOnce(() => {
    throw new Error("Launch failed");
  });
  await f.execute("submit_plan");
  await expect(f.completeApproval()).rejects.toThrow("Launch failed");
  f.controller.settled({ aborted: false }, f.ctx);
  expect({
    outcomes: f.outcomes.mock.calls,
    sends: f.sendImplementationMessage.mock.calls,
  }).toStrictEqual({
    outcomes: [
      [
        {
          version: 1,
          event: "review",
          decision: "current",
          path: plan.path,
          revision: plan.revision,
        },
      ],
      [
        {
          version: 1,
          event: "implementation-failed",
          path: plan.path,
          revision: plan.revision,
          reason: "Error: Launch failed",
        },
      ],
    ],
    sends: [[implementationContext(plan, "/fixture/session.jsonl")]],
  });
});

it.each(["input", "show", "review", "open"])(
  "does not revive approval after %s during the post-review idle check",
  async (action) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Context\nRequested work.\n");
    const plan = f.openPlan("session-one").read();
    const checking = Promise.withResolvers<void>();
    const secondCheck = Promise.withResolvers<void>();
    f.review.mockResolvedValueOnce({
      decision: "current",
      presentedPlan: plan,
    });
    f.ensureSubagentsIdle.mockResolvedValueOnce().mockImplementationOnce(() => {
      secondCheck.resolve();
      return checking.promise;
    });
    const submitted = f.execute("submit_plan");
    await Promise.race([
      secondCheck.promise,
      submitted.then(() => {
        throw new Error("submit_plan finished before the second idle check.");
      }),
    ]);
    if (action === "input") {
      f.controller.input();
    } else {
      await f.command(action === "show" ? "" : action);
    }
    checking.resolve();
    const result = await submitted;
    await f.completeApproval();
    expect({
      decision: result.details.decision,
      sends: f.sendImplementationMessage.mock.calls,
    }).toStrictEqual({ decision: "cancel", sends: [] });
  },
);

it("rechecks idle research after the approval choice before accepting it", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  const plan = f.openPlan("session-one").read();
  f.review.mockResolvedValueOnce({ decision: "current", presentedPlan: plan });
  f.ensureSubagentsIdle
    .mockResolvedValueOnce()
    .mockRejectedValueOnce(new Error("Research is active"));
  await expect(f.execute("submit_plan")).rejects.toThrow("Research is active");
  await f.completeApproval();
  expect({
    outcomes: f.outcomes.mock.calls,
    sends: f.sendImplementationMessage.mock.calls,
  }).toStrictEqual({ outcomes: [], sends: [] });
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
      notifications: vi.mocked(f.ctx.ui.notify).mock.calls,
      exists: f.openPlan("session-one").exists(),
      displayed: f.presentPlan.mock.calls,
      active: (await f.call("write", { path: "project.ts" }))?.block,
      modelTurns: f.sendUserMessage.mock.calls,
      implementation: f.sendImplementationMessage.mock.calls,
    }).toStrictEqual({
      notifications: [[message, "info"]],
      exists: false,
      displayed: [],
      active: true,
      modelTurns: [],
      implementation: [],
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
    displays: f.presentPlan.mock.calls,
    active: (await f.call("write", { path: "project.ts" }))?.block,
    configured: f.configure.mock.calls,
    disposed: f.disposed.mock.calls,
    modelTurns: f.sendUserMessage.mock.calls,
  }).toStrictEqual({
    initiallyMissing: true,
    displays: [[plan], [plan]],
    active: true,
    configured: [["session-one"]],
    disposed: [],
    modelTurns: [],
  });
});

it.each([false, true])(
  "opens the actual saved plan without approval (editor failure: %s)",
  async (failure) => {
    const f = fixture();
    f.files.replace(f.path(), "# Earlier plan\n");
    vi.mocked(f.editor.open).mockImplementationOnce(async (path) => {
      f.files.replace(path, "# Saved editor changes\n");
      if (failure) {
        throw new Error("Fixture editor failed");
      }
    });
    await f.command("open");
    expect({
      files: vi.mocked(f.editor.open).mock.calls,
      displayed: f.presentPlan.mock.calls,
      active: (await f.call("write", { path: "project.ts" }))?.block,
      modelTurns: f.sendUserMessage.mock.calls,
      implementation: f.sendImplementationMessage.mock.calls,
    }).toStrictEqual({
      files: [[f.path()]],
      displayed: [[f.openPlan("session-one").read()]],
      active: true,
      modelTurns: [],
      implementation: [],
    });
  },
);

it("escapes untrusted editor errors before native notifications", async () => {
  const f = fixture();
  f.files.replace(f.path(), "# Context\nRequested work.\n");
  f.editor.open.mockRejectedValueOnce(new Error("\u001B[8mconcealed\u001B[0m"));
  await f.command("open");
  expect(vi.mocked(f.ctx.ui.notify).mock.calls).toStrictEqual([
    ["Enabled plan mode", "info"],
    ["Cannot edit the plan: Error: \\u001b[8mconcealed\\u001b[0m", "error"],
  ]);
});

it("does not manufacture a plan when open is requested before the first write", async () => {
  const f = fixture();
  await f.command("open");
  expect({
    exists: f.openPlan("session-one").exists(),
    editor: vi.mocked(f.editor.open).mock.calls,
    modelTurns: f.sendUserMessage.mock.calls,
  }).toStrictEqual({ exists: false, editor: [], modelTurns: [] });
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
    f.editor.open.mockReturnValueOnce(finished.promise);
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
      displayed: f.presentPlan.mock.calls,
      implementation: f.sendImplementationMessage.mock.calls,
    }).toStrictEqual({ displayed: [], implementation: [] });
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
    f.review.mockResolvedValueOnce({
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
      implementation: f.sendImplementationMessage.mock.calls,
    }).toStrictEqual({ boundary: undefined, implementation: [] });
  },
);

it("delivers a pathless exit notice when plan metadata is unreadable", async () => {
  const f = fixture();
  await f.command("");
  await f.command("exit");
  vi.spyOn(f.files, "kind").mockImplementationOnce(() => {
    throw new Error("Metadata failure");
  });
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
    f.review.mockResolvedValueOnce({
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
      continuations: f.sendImplementationMessage.mock.calls.map(
        ([content]) => content,
      ),
      imageInSummary:
        boundary?.entries?.some(
          (entry) =>
            entry.type === "compaction" &&
            entry.summary.includes(feedbackImage.data),
        ) ?? false,
    }).toStrictEqual({
      images: [feedbackImage],
      continuations: [
        [
          {
            type: "text",
            text: implementationContext(plan, "/fixture/session.jsonl"),
          },
          { type: "text", text: "User image feedback:" },
          feedbackImage,
        ],
      ],
      imageInSummary: false,
    });
  },
);

it("waits for entry consent before creating a plan or restricting tools", async () => {
  const f = fixture();
  const answer = Promise.withResolvers<boolean>();
  f.confirm.mockReturnValueOnce(answer.promise);
  const entering = f.controller.enterTool(f.ctx);

  expect({
    question: f.confirm.mock.calls.map(([title, message]) => ({
      title,
      message,
    })),
    planExists: f.openPlan("session-one").exists(),
    configure: f.configure.mock.calls,
    saved: f.branch,
    projectWrite: await f.call("write", { path: "project.ts" }),
  }).toStrictEqual({
    question: [
      {
        title: "Enter Plan mode?",
        message:
          "Pi will investigate and draft an implementation plan for your approval. Only the plan file may be edited in Plan mode. Entering does not approve implementation.",
      },
    ],
    planExists: false,
    configure: [],
    saved: [],
    projectWrite: undefined,
  });

  answer.resolve(true);
  const result = await entering;
  const instructions = planningPrompt(f.path());
  expect({
    result,
    planExists: f.openPlan("session-one").exists(),
    configure: f.configure.mock.calls,
    projectWrite: await f.call("write", { path: "project.ts" }),
  }).toStrictEqual({
    result: {
      content: [{ type: "text", text: instructions }],
      details: { status: "active", path: f.path() },
      structuredContent: { status: "active", path: f.path(), instructions },
    },
    planExists: false,
    configure: [["session-one"]],
    projectWrite: {
      block: true,
      reason: `Only the active plan may be edited: ${f.path()}`,
    },
  });
});

it("keeps ordinary mode when entry consent is declined or cancelled", async () => {
  const f = fixture();
  f.confirm.mockResolvedValueOnce(false);
  const instructions =
    "Plan mode was not entered. Continue in the current mode and follow the user's request.";
  expect({
    result: await f.controller.enterTool(f.ctx),
    planExists: f.openPlan("session-one").exists(),
    configure: f.configure.mock.calls,
    saved: f.branch,
    projectWrite: await f.call("write", { path: "project.ts" }),
  }).toStrictEqual({
    result: {
      content: [{ type: "text", text: instructions }],
      details: { status: "declined" },
      structuredContent: { status: "declined", instructions },
    },
    planExists: false,
    configure: [],
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
    prompts: f.confirm.mock.calls,
    planExists: f.openPlan("session-one").exists(),
    configure: f.configure.mock.calls,
    saved: f.branch,
  }).toStrictEqual({
    prompts: [],
    planExists: false,
    configure: [],
    saved: [],
  });
});

it.each(["tool", "run", "restore", "shutdown", "human exit"] as const)(
  "rejects a late affirmative entry response after %s cancellation",
  async (cause) => {
    const f = fixture();
    const answer = Promise.withResolvers<boolean>();
    const tool = new AbortController();
    f.confirm.mockReturnValueOnce(answer.promise);
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
      dialogAborted: f.confirm.mock.calls[0]?.[2]?.signal?.aborted,
      projectWrite: await f.call("write", { path: "project.ts" }),
      savedActive: f.branch.at(-1),
    }).toStrictEqual({
      dialogAborted: true,
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
  f.confirm.mockReturnValueOnce(answer.promise);
  const entering = f.controller.enterTool(f.ctx);
  vi.spyOn(f.ctx.sessionManager, "getSessionId").mockReturnValue("replacement");
  answer.resolve(true);
  await expect(entering).rejects.toThrow("session changed");
  expect(f.configure.mock.calls).toStrictEqual([]);
});

it("does not open overlapping entry requests", async () => {
  const f = fixture();
  const answer = Promise.withResolvers<boolean>();
  f.confirm.mockReturnValueOnce(answer.promise);
  const entering = f.controller.enterTool(f.ctx);
  await expect(f.controller.enterTool(f.ctx)).rejects.toThrow(
    "entry request is already open",
  );
  answer.resolve(false);
  await entering;
  expect(f.confirm).toHaveBeenCalledTimes(1);
});

it("does not request entry consent again while Plan mode is active", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Existing draft\n");
  await f.controller.enterTool(f.ctx);
  expect({
    prompts: f.confirm.mock.calls,
    draft: f.files.read(f.path()),
    configure: f.configure.mock.calls,
  }).toStrictEqual({
    prompts: [],
    draft: "# Existing draft\n",
    configure: [["session-one"]],
  });
});

it("can request consent again after leaving Plan mode", async () => {
  const f = fixture();
  await f.command("");
  await f.command("exit");
  f.confirm.mockResolvedValueOnce(true);
  await f.controller.enterTool(f.ctx);
  expect(f.confirm).toHaveBeenCalledTimes(1);
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
});

it("honours the explicit startup flag without a consent UI", () => {
  const f = fixture();
  f.ctx.hasUI = false;
  f.startInPlan.mockReturnValueOnce(true);
  f.controller.start({ reason: "startup" }, f.ctx);
  expect({
    reviewAvailability: f.setReviewAvailable.mock.calls,
    prompts: f.confirm.mock.calls,
    planExists: f.openPlan("session-one").exists(),
    configure: f.configure.mock.calls,
  }).toStrictEqual({
    prompts: [],
    planExists: false,
    configure: [["session-one"]],
    reviewAvailability: [[false], [false], [true]],
  });
});

it("enters without a model call, preserves drafts, and releases child capabilities on exit", async () => {
  const f = fixture();
  await f.command("");
  const path = f.path();
  f.files.replace(path, "# Existing draft\n");
  expect(f.configure.mock.calls).toStrictEqual([["session-one"]]);
  await f.command("exit");
  expect(f.disposed.mock.calls).toStrictEqual([[]]);
  await f.command("");
  expect(f.files.read(f.path())).toBe("# Existing draft\n");
  expect([
    ...f.sendUserMessage.mock.calls,
    ...f.sendImplementationMessage.mock.calls,
  ]).toStrictEqual([]);
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
    vi.mocked(f.ctx.ui.notify).mockClear();
    if (exit === "command") {
      await f.command("exit");
    } else {
      f.controller.toggle(f.ctx);
    }
    expect({
      notifications: vi.mocked(f.ctx.ui.notify).mock.calls,
      reminder: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
      planExists: f.openPlan("session-one").exists(),
    }).toStrictEqual({
      notifications: exit === "command" ? [["Exited plan mode", "info"]] : [],
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
  f.confirm.mockResolvedValueOnce(true);
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
    vi.mocked(f.ctx.ui.notify).mockClear();
    if (condition === "missing") {
      f.files.contents.delete(f.path());
    } else if (condition === "empty") {
      f.files.replace(f.path(), "  \n");
    } else {
      vi.spyOn(f.files, "read").mockImplementationOnce(() => {
        throw new Error("Fixture read failure");
      });
    }
    expect({
      context: f.controller.compact(f.ctx),
      notifications: vi.mocked(f.ctx.ui.notify).mock.calls,
      sends: [
        ...f.sendUserMessage.mock.calls,
        ...f.sendImplementationMessage.mock.calls,
      ],
    }).toStrictEqual({
      context: undefined,
      notifications:
        condition === "unreadable"
          ? [
              [
                "Cannot restore plan context: Error: Fixture read failure",
                "warning",
              ],
            ]
          : [],
      sends: [],
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
    vi.mocked(f.ctx.ui.notify).mockClear();
    f.review.mockResolvedValueOnce({
      decision,
      presentedPlan: f.openPlan("session-one").read(),
    });
    await f.execute("submit_plan");
    expect(vi.mocked(f.ctx.ui.notify).mock.calls).toStrictEqual([]);
  },
);

it("offers same-session context clearing during approval", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Approved plan\n");
  f.select.mockResolvedValueOnce("Yes, clear context");
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
    child: childPolicy({ toolName: "bash", input }),
    input,
    confirmations: f.confirm.mock.calls,
  }).toStrictEqual({
    parent: undefined,
    child: undefined,
    input: { command, timeout: 7 },
    confirmations: [],
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
      child: childPolicy({ toolName, input }),
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
    f.select.mockResolvedValueOnce(choice);
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
  f.select.mockImplementationOnce(async () => {
    f.files.replace(path, "# Changed plan\n");
    return "Yes, keep context";
  });
  await expect(f.execute("submit_plan")).rejects.toThrow(
    "changed during review",
  );
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  f.select.mockResolvedValueOnce("Yes, keep context");
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
    f.review.mockImplementationOnce(async (_ctx, request) => {
      f.files.replace(
        f.path(),
        "# Edited plan\n\nImplement the updated approach.\n",
      );
      const presentedPlan = request.read();
      request.present(presentedPlan);
      return { decision, presentedPlan };
    });
    const updates = vi.fn<(update: PlanningResult) => void>();
    const result = await f.controller.submit(f.ctx, undefined, updates);
    const presentedPlan = f.openPlan("session-one").read();
    expect({
      details: result.details,
      updates: updates.mock.calls,
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
      updates: [
        [
          {
            content: [{ type: "text", text: "Review the presented plan." }],
            details: { decision: "pending", presentedPlan },
          },
        ],
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
    f.review.mockImplementationOnce(async (_ctx, request) => {
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
    f.select.mockResolvedValueOnce("Yes, keep context");
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
    f.review.mockResolvedValueOnce({ decision, presentedPlan: plan, feedback });
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
    f.select
      .mockResolvedValueOnce("Add a comment")
      .mockResolvedValueOnce(label);
    vi.mocked(f.ctx.ui.input).mockResolvedValueOnce("Keep compatibility.");
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
  f.review.mockImplementationOnce(async (_ctx, request) => {
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
  f.review.mockImplementationOnce(async (_ctx, request) => {
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
  f.select.mockReturnValueOnce(answer.promise);
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
    f.review.mockResolvedValueOnce({
      decision,
      presentedPlan: f.openPlan("session-one").read(),
    });
    await f.execute("submit_plan");
    const boundary = await f.prepareClear({ outcome: "completed" }, f.ctx);
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
    f.commit(boundary);
    f.controller.settled({ aborted: false }, f.ctx);
    f.controller.settled({ aborted: false }, f.ctx);
    const plan = f.openPlan("session-one").read();
    expect({
      sends: [
        ...f.sendUserMessage.mock.calls,
        ...f.sendImplementationMessage.mock.calls,
      ],
      sessionId: f.ctx.sessionManager.getSessionId(),
      plan,
      projectWrite: await f.call("write", { path: "project.ts" }),
      prompt: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
      reviewAvailability: f.setReviewAvailable.mock.calls,
    }).toStrictEqual({
      sends: [[implementationContext(plan, "/fixture/session.jsonl")]],
      sessionId: "session-one",
      plan: {
        path: f.path(),
        revision: plan.revision,
        content: "# Approved plan\n",
      },
      projectWrite: undefined,
      prompt: undefined,
      reviewAvailability: [[false], [true], [false]],
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
    f.review.mockResolvedValueOnce({
      decision,
      presentedPlan: f.openPlan("session-one").read(),
    });
    await f.execute("submit_plan");
    f.commit(await f.prepareClear({ outcome: "completed" }, f.ctx));
    f.controller.beforeSettle({ outcome }, f.ctx);
    f.controller.settled({ aborted: false }, f.ctx);
    expect(f.sendImplementationMessage.mock.calls).toStrictEqual([]);
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
    f.review.mockResolvedValueOnce({
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
    expect([
      ...f.sendUserMessage.mock.calls,
      ...f.sendImplementationMessage.mock.calls,
    ]).toStrictEqual([]);
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
    f.select.mockResolvedValueOnce("Yes, clear context");
    await f.execute("submit_plan");
    expect(await f.prepareClear({ outcome }, f.ctx)).toBeUndefined();
    f.controller.settled({ aborted: outcome === "aborted" }, f.ctx);
    expect([
      ...f.sendUserMessage.mock.calls,
      ...f.sendImplementationMessage.mock.calls,
    ]).toStrictEqual([]);
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
    f.review.mockResolvedValueOnce({
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
      continuations: f.sendImplementationMessage.mock.calls,
      projectWrite: await f.call("write", { path: "project.ts" }),
    }).toStrictEqual({
      boundary: undefined,
      continuations: [],
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
  f.controller.compact(f.ctx);
  expect(f.setReviewAvailable.mock.calls).toStrictEqual([
    [false],
    [true],
    [true],
    [true],
  ]);
  expect(f.path()).toBe(path);
  expect(f.files.read(path)).toBe("# Durable plan\n");
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  expect([
    ...f.sendUserMessage.mock.calls,
    ...f.sendImplementationMessage.mock.calls,
  ]).toStrictEqual([]);
});

it.each([false, true])(
  "forks the edited intermediate plan with reload=%s",
  async (reload) => {
    const f = fixture();
    await f.command("");
    const original = f.path();
    f.files.replace(original, "# Original plan\n");

    const sessionId = vi.spyOn(f.ctx.sessionManager, "getSessionId");
    sessionId.mockReturnValue("first-fork");
    f.controller.start({ reason: "fork" }, f.ctx);
    const first = f.openPlan("first-fork");
    f.files.replace(first.path, "# Edited fork plan\n");

    if (reload) {
      f.controller.start({ reason: "reload" }, f.ctx);
    }

    sessionId.mockReturnValue("nested-fork");
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
    expect([
      ...f.sendUserMessage.mock.calls,
      ...f.sendImplementationMessage.mock.calls,
    ]).toStrictEqual([]);
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

    const sessionId = vi.spyOn(f.ctx.sessionManager, "getSessionId");
    sessionId.mockReturnValue("nested-fork");
    f.controller.start({ reason: "fork" }, f.ctx);
    const nested = f.openPlan("nested-fork");

    expect({
      original: original.exists() ? original.read().content : null,
      first: first.read().content,
      nested: nested.read().content,
      configured: f.configure.mock.calls,
      projectWrite: await f.call("write", { path: "project.ts" }),
    }).toStrictEqual({
      original: hasDraft ? "# Inactive plan\n" : null,
      first: "# Edited inactive plan\n",
      nested: "# Edited inactive plan\n",
      configured: [],
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
  vi.spyOn(f.ctx.sessionManager, "getSessionId").mockReturnValue(
    "inactive-fork",
  );
  f.controller.start({ reason: "fork" }, f.ctx);
  expect(f.controller.prompt({ systemPrompt: "Base" }, f.ctx)).toStrictEqual({
    message: {
      customType: "dotfiles:planning-exit:v1",
      content: planExitReminder(f.path()),
      display: false,
    },
  });
  expect(f.controller.prompt({ systemPrompt: "Base" }, f.ctx)).toBeUndefined();
  expect([
    ...f.sendUserMessage.mock.calls,
    ...f.sendImplementationMessage.mock.calls,
  ]).toStrictEqual([]);
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
    expect(f.ctx.ui.select).not.toHaveBeenCalled();
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
    expect(
      await f.call("write", { path, content: "# Replacement plan\n" }),
    ).toBeUndefined();

    f.files.replace(path, "# Replacement plan\n");
    f.select.mockResolvedValueOnce("Yes, keep context");
    await f.execute("submit_plan");
    expect(f.ctx.ui.select).toHaveBeenCalledOnce();
    await f.completeApproval();
    expect(await f.call("write", { path: "project.ts" })).toBeUndefined();
  },
);

it("blocks model approval while subagents are active but permits human exit", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Plan\n\nImplement the requested change.\n");
  f.ensureSubagentsIdle.mockRejectedValueOnce(
    new Error("A subagent is still active. Wait or cancel it."),
  );
  await expect(f.execute("submit_plan")).rejects.toThrow(
    "subagent is still active",
  );
  const beforeExit = (await f.call("write", { path: "project.ts" }))?.block;
  await f.command("exit");
  expect({
    checks: f.ensureSubagentsIdle.mock.calls.map(([signal]) => signal.aborted),
    reviews: f.select.mock.calls,
    beforeExit,
    afterExit: await f.call("write", { path: "project.ts" }),
  }).toStrictEqual({
    checks: [true],
    reviews: [],
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
      child: childPolicy({ toolName, input }),
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
      child: childPolicy({ toolName, input })?.block,
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
      child: childPolicy({ toolName: "subagent", input }),
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
    child: childPolicy({ toolName: "subagent", input })?.block,
  }).toStrictEqual({ parent: true, child: true });
});

it.each(["ask_user", "submit_plan", "enter_plan_mode", "write", "edit"])(
  "blocks %s in a research child",
  (toolName) => {
    expect(childPolicy({ toolName, input: {} })).toStrictEqual({
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
    f.select.mockResolvedValueOnce("Yes, clear context");
    await f.execute("submit_plan");
    if (action === "revise") {
      f.select.mockResolvedValueOnce("No, keep planning");
      await f.execute("submit_plan");
    } else {
      await f.command("exit");
      await f.command("");
    }
    f.controller.settled({ aborted: false }, f.ctx);
    expect([
      ...f.sendUserMessage.mock.calls,
      ...f.sendImplementationMessage.mock.calls,
    ]).toStrictEqual([]);
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
    f.select.mockResolvedValueOnce("Yes, clear context");
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
    expect([
      ...f.sendUserMessage.mock.calls,
      ...f.sendImplementationMessage.mock.calls,
    ]).toStrictEqual([]);
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
  },
);

it("rechecks native jobs before clearing the approved context", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Approved plan\n");
  f.select.mockResolvedValueOnce("Yes, clear context");
  await f.execute("submit_plan");
  f.ensureSubagentsIdle.mockRejectedValueOnce(new Error("A job is active"));
  expect(await f.prepareClear({ outcome: "completed" }, f.ctx)).toBeUndefined();
  f.controller.settled({ aborted: false }, f.ctx);
  expect([
    ...f.sendUserMessage.mock.calls,
    ...f.sendImplementationMessage.mock.calls,
  ]).toStrictEqual([]);
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
    f.select.mockResolvedValueOnce("Yes, clear context");
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
      f.ensureSubagentsIdle.mockRejectedValueOnce(new Error("A job is active"));
      await f.controller.verifyClear(f.ctx);
    }
    expect(
      f.controller.beforeSettle({ outcome: "completed" }, f.ctx),
    ).toBeUndefined();
    f.controller.settled({ aborted: false }, f.ctx);
    expect([
      ...f.sendUserMessage.mock.calls,
      ...f.sendImplementationMessage.mock.calls,
    ]).toStrictEqual([]);
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
  },
);

it("keeps the live session usable when restoring its replacement fails", async () => {
  const f = fixture();
  await f.command("");
  vi.spyOn(f.files, "ensureDirectory").mockImplementationOnce(() => {
    throw new Error("fixture restore failure");
  });

  expect(() => f.controller.restore(f.ctx)).toThrow("fixture restore failure");
  expect(f.disposed.mock.calls).toStrictEqual([]);
  await expect(
    f.call("write", { path: f.path(), content: "draft" }),
  ).resolves.toBeUndefined();
});

it("rejects entry when research configuration cannot be loaded", async () => {
  const f = fixture();
  f.configure.mockImplementationOnce(() => {
    throw new Error("Invalid planning.json");
  });

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
    vi.spyOn(f.ctx.sessionManager, "getSessionId").mockReturnValue(
      "compacted-fork",
    );
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
    disposed: f.disposed.mock.calls,
  }).toStrictEqual({ projectWrite: undefined, disposed: [[]] });
});
