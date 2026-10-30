import type { BoundaryResult } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import {
  createPlanning,
  type PlanningContext,
  type PlanningDependencies,
  type PlanningResult,
} from "../src/controller.ts";
import { childPolicy } from "../src/child.ts";
import {
  attachedPlanContext,
  implementationContext,
  planExitReminder,
  planningPrompt,
} from "../src/prompt.ts";
import { reviewPlan } from "../src/review.ts";
import { stateEntry } from "../src/session.ts";
import { PlanStore } from "../src/store.ts";
import { MemoryFiles } from "./memory-files.ts";

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
  const select = vi.fn<PlanningContext["ui"]["select"]>();
  const confirm = vi.fn<PlanningContext["ui"]["confirm"]>();
  const run = new AbortController();
  const ctx: PlanningContext = {
    signal: run.signal,
    cwd: directory,
    mode: "rpc",
    hasUI: true,
    sessionManager: {
      getSessionId: () => initialId,
      getBranch: () => branch,
      getSessionFile: () => "/fixture/session.jsonl",
    },
    ui: {
      notify: vi.fn<PlanningContext["ui"]["notify"]>(),
      setStatus: vi.fn<PlanningContext["ui"]["setStatus"]>(),
      select,
      confirm,
      custom: async () => ({
        decision: "cancel",
        presentedPlan: { path: "", revision: "", content: "" },
      }),
    },
  };
  let identity = 0;
  const readOnlyTools = vi.fn<PlanningDependencies["readOnlyTools"]>(() => []);
  const ensureSubagentsIdle = vi.fn<(signal: AbortSignal) => Promise<void>>(
    async () => {},
  );
  const review = vi.fn<PlanningDependencies["review"]>((context, request) =>
    reviewPlan(context, request, async () => {}),
  );
  const controller = createPlanning({
    openPlan,
    configure,
    sendUserMessage,
    recordSavedState: (data) => {
      branch.push({ type: "custom", customType: stateEntry, data });
    },
    readOnlyTools,
    ensureSubagentsIdle,
    startInPlan: () => false,
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
  const command = (args: string) => controller.command(args, ctx);
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
    disposed,
    configure,
    sendUserMessage,
    files,
    openPlan,
    readOnlyTools,
    ensureSubagentsIdle,
    review,
    commit,
  };
}

it("enters without a model call, preserves drafts, and releases child capabilities on exit", async () => {
  const f = fixture();
  await f.command("");
  const path = f.path();
  f.files.replace(path, "# Existing draft\n");
  expect(f.configure.mock.calls).toStrictEqual([["session-one"]]);
  await f.command("");
  expect(f.disposed.mock.calls).toStrictEqual([[]]);
  await f.command("");
  expect(f.files.read(f.path())).toBe("# Existing draft\n");
  expect(f.sendUserMessage).not.toHaveBeenCalled();
});

it("refreshes planning guidance across turns, compaction and re-entry", async () => {
  const f = fixture();
  await f.command("");
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
  await f.command("");
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
    systemPrompt: `Base instructions\n\n${planningPrompt(f.path())}`,
  });
});

it.each(["command", "shortcut", "approval"] as const)(
  "reports plan exit once after %s without implying approval",
  async (exit) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Existing plan\n");
    if (exit === "command") {
      await f.command("");
    } else if (exit === "shortcut") {
      f.controller.toggle(f.ctx);
    } else {
      f.select.mockResolvedValueOnce("Approve and keep context");
      await f.execute("submit_plan");
    }
    const expected = {
      message: {
        customType: "dotfiles:planning-exit:v1",
        content: `Plan mode has ended. Plan file: ${f.path()}\nUse the normal file tools to read or update the plan. Follow the user's current request; leaving Plan mode does not itself approve implementation.`,
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

it("preserves an undelivered exit reminder through restart", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Retained plan\n");
  await f.command("");
  f.controller.shutdown();
  f.controller.start({ reason: "startup" }, f.ctx);
  expect(f.controller.prompt({ systemPrompt: "Base" }, f.ctx)).toMatchObject({
    message: {
      customType: "dotfiles:planning-exit:v1",
      content: `Plan mode has ended. Plan file: ${f.path()}\nUse the normal file tools to read or update the plan. Follow the user's current request; leaving Plan mode does not itself approve implementation.`,
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
  await f.command("");
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
    await f.command("");
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
      sends: f.sendUserMessage.mock.calls,
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
    await f.command("");
    expect(f.controller.turnEnd({ outcome }, f.ctx)).toBeUndefined();
    expect(f.controller.prompt({ systemPrompt: "Base" }, f.ctx)).toStrictEqual({
      message: {
        customType: "dotfiles:planning-exit:v1",
        content: planExitReminder(f.path()),
        display: false,
      },
    });
    expect(
      f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
    ).toBeUndefined();
  },
);

it("offers same-session context clearing during approval", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Approved plan\n");
  f.select.mockResolvedValueOnce("Approve and clear context");
  expect((await f.execute("submit_plan")).details).toMatchObject({
    decision: "clear",
  });
});

it("restricts parent and nested mutations while preserving plan edits and inspections", async () => {
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
  expect(await f.call("bash", { command: "rm file" })).toMatchObject({
    block: true,
  });
  expect(
    await f.call("ask_user", { question: "Requirement?" }),
  ).toBeUndefined();
  expect(await f.call("subagent", { agent: "worker" })).toMatchObject({
    block: true,
  });
  const input = { command: "git diff --stat" };
  expect(await f.call("bash", input)).toBeUndefined();
  expect(input.command).toContain("--no-ext-diff --no-textconv");
  f.confirm.mockResolvedValueOnce(false).mockResolvedValueOnce(true);
  expect(
    await f.call("bash", { command: "python3 investigate.py" }),
  ).toMatchObject({ block: true });
  expect(
    await f.call("bash", { command: "python3 investigate.py" }),
  ).toBeUndefined();
  expect(await f.call("edit", { path: "src/file.ts" })).toMatchObject({
    block: true,
  });
});

it.each([undefined, "Revise the plan"])(
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
    return "Approve and keep context";
  });
  await expect(f.execute("submit_plan")).rejects.toThrow(
    "changed during review",
  );
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  f.select.mockResolvedValueOnce("Approve and keep context");
  await f.execute("submit_plan");
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
        decision,
        path: presentedPlan.path,
        revision: presentedPlan.revision,
        presentedPlan,
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
  answer.resolve("Approve and keep context");
  await pending;
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
});

it("clears context in the same session and starts implementation only after commit", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Approved plan\n");
  f.select.mockResolvedValueOnce("Approve and clear context");
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
    sends: f.sendUserMessage.mock.calls,
    sessionId: f.ctx.sessionManager.getSessionId(),
    plan,
    projectWrite: await f.call("write", { path: "project.ts" }),
    prompt: f.controller.prompt({ systemPrompt: "Base" }, f.ctx),
  }).toStrictEqual({
    sends: [
      [
        `Implement the approved plan at ${plan.path} (approved revision ${plan.revision}).`,
        { expandPromptTemplates: false },
      ],
    ],
    sessionId: "session-one",
    plan: {
      path: f.path(),
      revision: plan.revision,
      content: "# Approved plan\n",
    },
    projectWrite: undefined,
    prompt: undefined,
  });
});

it.each(["before", "after"] as const)(
  "rejects a changed plan %s context clearing",
  async (when) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Approved plan\n");
    f.select.mockResolvedValueOnce("Approve and clear context");
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
    expect(f.sendUserMessage.mock.calls).toStrictEqual([]);
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
    f.select.mockResolvedValueOnce("Approve and clear context");
    await f.execute("submit_plan");
    expect(await f.prepareClear({ outcome }, f.ctx)).toBeUndefined();
    f.controller.settled({ aborted: outcome === "aborted" }, f.ctx);
    expect(f.sendUserMessage.mock.calls).toStrictEqual([]);
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
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
  expect(f.path()).toBe(path);
  expect(f.files.read(path)).toBe("# Durable plan\n");
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  expect(f.sendUserMessage).not.toHaveBeenCalled();
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
    expect(f.sendUserMessage).not.toHaveBeenCalled();
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
  await f.command("");
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
  expect(f.sendUserMessage.mock.calls).toStrictEqual([]);
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
    f.select.mockResolvedValueOnce("Approve and keep context");
    await f.execute("submit_plan");
    expect(f.ctx.ui.select).toHaveBeenCalledOnce();
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
  await f.command("");
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
    f.readOnlyTools.mockReturnValue([toolName]);
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
it("guards shell investigation in a research child", () => {
  expect(
    childPolicy({ toolName: "bash", input: { command: "python3 inspect.py" } }),
  ).toMatchObject({ block: true });
  expect(
    childPolicy({ toolName: "bash", input: { command: "cat README.md" } }),
  ).toBeUndefined();
});

it.each(["revise", "exit"])(
  "invalidates an older clear-context approval on %s",
  async (action) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Plan\n");
    f.select.mockResolvedValueOnce("Approve and clear context");
    await f.execute("submit_plan");
    if (action === "revise") {
      f.select.mockResolvedValueOnce("Revise the plan");
      await f.execute("submit_plan");
    } else {
      await f.command("");
      await f.command("");
    }
    f.controller.settled({ aborted: false }, f.ctx);
    expect(f.sendUserMessage).not.toHaveBeenCalled();
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
    f.select.mockResolvedValueOnce("Approve and clear context");
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
    expect(f.sendUserMessage.mock.calls).toStrictEqual([]);
    expect(await f.call("write", { path: "project.ts" })).toMatchObject({
      block: true,
    });
  },
);

it("rechecks native jobs before clearing the approved context", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Approved plan\n");
  f.select.mockResolvedValueOnce("Approve and clear context");
  await f.execute("submit_plan");
  f.ensureSubagentsIdle.mockRejectedValueOnce(new Error("A job is active"));
  expect(await f.prepareClear({ outcome: "completed" }, f.ctx)).toBeUndefined();
  f.controller.settled({ aborted: false }, f.ctx);
  expect(f.sendUserMessage.mock.calls).toStrictEqual([]);
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
    f.select.mockResolvedValueOnce("Approve and clear context");
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
    expect(f.sendUserMessage.mock.calls).toStrictEqual([]);
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

it("blocks tools explicitly when planning settings cannot be read", async () => {
  const f = fixture();
  await f.command("");
  f.readOnlyTools.mockImplementationOnce(() => {
    throw new Error("Invalid planning.json");
  });

  await expect(f.call("write", { path: "project.ts" })).resolves.toStrictEqual({
    block: true,
    reason: "Planning settings are unavailable: Error: Invalid planning.json",
  });
});

it.each([true, false])(
  "preserves draft lineage through compaction (active: %s)",
  async (active) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Compacted draft");
    if (!active) {
      await f.command("");
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
