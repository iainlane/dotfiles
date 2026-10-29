import { afterEach, expect, it, vi } from "vitest";
import {
  createPlanning,
  type PlanningCommandContext,
  type PlanningDependencies,
  type ResearchParameters,
} from "../src/controller.ts";
import { childPolicy } from "../src/child.ts";
import { planningPrompt } from "../src/prompt.ts";
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
  const listeners = new Map<string, Set<(value: unknown) => void>>();
  const events = {
    emit(event: string, value: unknown) {
      for (const callback of listeners.get(event) ?? []) {
        callback(value);
      }
    },
    on(event: string, callback: (value: unknown) => void) {
      const callbacks = listeners.get(event) ?? new Set();
      callbacks.add(callback);
      listeners.set(event, callbacks);
      return () => {
        callbacks.delete(callback);
      };
    },
  };
  const disposed = vi.fn<() => void>();
  const configure = vi.fn<PlanningDependencies["configure"]>(() => [disposed]);
  const sendUserMessage = vi.fn<PlanningDependencies["sendUserMessage"]>();
  const select = vi.fn<PlanningCommandContext["ui"]["select"]>();
  const confirm = vi.fn<PlanningCommandContext["ui"]["confirm"]>();
  const ctx: PlanningCommandContext = {
    cwd: directory,
    mode: "rpc",
    hasUI: true,
    sessionManager: {
      getSessionId: () => initialId,
      getBranch: () => branch,
      getSessionFile: () => "/fixture/session.jsonl",
    },
    ui: {
      notify: vi.fn<PlanningCommandContext["ui"]["notify"]>(),
      setStatus: vi.fn<PlanningCommandContext["ui"]["setStatus"]>(),
      select,
      confirm,
      custom: async () => "cancel",
    },
    handoff: vi.fn<PlanningCommandContext["handoff"]>(async () => {}),
  };
  let identity = 0;
  const readOnlyTools = vi.fn<PlanningDependencies["readOnlyTools"]>(() => []);
  const controller = createPlanning({
    openPlan,
    configure,
    sendUserMessage,
    recordSavedState: (data) => {
      branch.push({ type: "custom", customType: stateEntry, data });
    },
    readOnlyTools,
    startInPlan: () => false,
    requestId: () => `ticket-${++identity}`,
    transport: {
      events,
      requestId: () => `research-${++identity}`,
      after: () => () => {},
    },
    review: (context, plan, signal) =>
      reviewPlan(context, plan, signal, (content) => ({
        render: () => [content],
        invalidate() {},
      })),
  });
  seed?.(openPlan);
  controller.start({ reason: "startup" }, ctx);
  cleanups.push(() => controller.shutdown());
  const command = (args: string) => controller.command(args, ctx);
  const execute = (_name: "submit_plan", _params = {}, signal?: AbortSignal) =>
    controller.submit(ctx, signal);
  const investigate = (params: ResearchParameters, signal?: AbortSignal) =>
    controller.investigate(params, ctx, signal);
  const call = (toolName: string, input: Record<string, unknown>) =>
    controller.toolCall({ toolName, input }, ctx);
  const path = () => openPlan(ctx.sessionManager.getSessionId()).path;
  return {
    select,
    confirm,
    directory,
    branch,
    controller,
    ctx,
    command,
    execute,
    investigate,
    call,
    path,
    disposed,
    configure,
    sendUserMessage,
    events,
    files,
    openPlan,
    readOnlyTools,
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
    compact: reminder,
    prompt: {
      systemPrompt: `Base instructions\n\n${planningPrompt(f.path())}`,
    },
  });
  await f.command("");
  expect({
    turns: Array.from({ length: 5 }, () => f.controller.turnEnd(event, f.ctx)),
    compact: f.controller.compact(f.ctx),
  }).toStrictEqual({
    turns: [undefined, undefined, undefined, undefined, undefined],
    compact: undefined,
  });
  await f.command("");
  f.controller.restore(f.ctx);
  expect(
    f.controller.prompt({ systemPrompt: "Base instructions" }, f.ctx),
  ).toStrictEqual({
    systemPrompt: `Base instructions\n\n${planningPrompt(f.path())}`,
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
    return "Approve in current conversation";
  });
  await expect(f.execute("submit_plan")).rejects.toThrow(
    "changed during review",
  );
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  f.select.mockResolvedValueOnce("Approve in current conversation");
  await f.execute("submit_plan");
  expect(await f.call("write", { path: "project.ts" })).toBeUndefined();
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
  answer.resolve("Approve in current conversation");
  await pending;
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
});

it("queues fresh handoff until settlement and binds its one-shot ticket to the revision", async () => {
  const f = fixture();
  await f.command("");
  const path = f.path();
  f.files.replace(path, "# Approved plan\n");
  f.select.mockResolvedValueOnce("Approve in a fresh conversation");
  await f.execute("submit_plan");
  expect(f.sendUserMessage).not.toHaveBeenCalled();
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  f.controller.settled({ aborted: false });
  f.controller.settled({ aborted: false });
  expect(f.sendUserMessage.mock.calls).toStrictEqual([
    ["/plan handoff ticket-1", { expandPromptTemplates: true }],
  ]);
  const command = f.sendUserMessage.mock.calls[0]?.[0];
  if (command === undefined) {
    throw new Error("Expected a queued planning handoff");
  }
  f.files.replace(path, "# Externally revised\n");
  await f.command(command.slice("/plan ".length));
  expect(f.ctx.handoff).not.toHaveBeenCalled();
  await f.command(command.slice("/plan ".length));
  expect(f.ctx.handoff).not.toHaveBeenCalled();
});

it("starts the fresh conversation with the approved document and source reference", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Approved plan\n");
  f.select.mockResolvedValueOnce("Approve in a fresh conversation");
  await f.execute("submit_plan");
  f.controller.settled({ aborted: false });
  const command = f.sendUserMessage.mock.calls[0]?.[0];
  if (command === undefined) {
    throw new Error("Expected a queued planning handoff");
  }
  await f.command(command.slice("/plan ".length));
  expect(vi.mocked(f.ctx.handoff).mock.calls).toStrictEqual([
    [
      {
        parentSession: "/fixture/session.jsonl",
        message: `Implement this approved plan.\n\nSource conversation: /fixture/session.jsonl\nPlan: ${f.path()}\nApproved revision: ${f.openPlan("session-one").read().revision}\n\n# Approved plan\n`,
      },
    ],
  ]);
});

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
    f.select.mockResolvedValueOnce("Approve in current conversation");
    await f.execute("submit_plan");
    expect(f.ctx.ui.select).toHaveBeenCalledOnce();
    expect(await f.call("write", { path: "project.ts" })).toBeUndefined();
  },
);

it("correlates research identity, ignores late reports and cancels transport on exit", async () => {
  const f = fixture();
  await f.command("");
  let request: object | undefined;
  f.events.on("prompt-template:subagent:request", (value) => {
    if (typeof value === "object" && value !== null) {
      request = value;
    }
  });
  const work = f.investigate({
    role: "explore",
    brief: "Find the relevant implementation and tests.",
  });
  expect(request).toMatchObject({
    context: "fresh",
    agent: "planning-explore",
    skill: false,
  });
  f.events.emit("prompt-template:subagent:response", {
    ...request,
    nodeId: "foreign",
    status: "completed",
    result: { kind: "text", text: "wrong" },
  });
  const cancelled = vi.fn<(value: unknown) => void>();
  f.events.on("prompt-template:subagent:cancel", cancelled);
  await f.command("");
  await expect(work).rejects.toThrow("cancelled");
  expect(cancelled).toHaveBeenCalledTimes(1);
  f.events.emit("prompt-template:subagent:response", {
    ...request,
    status: "completed",
    result: { kind: "text", text: "late" },
  });
  expect(f.sendUserMessage).not.toHaveBeenCalled();
});

it.each([
  ["web_enable", {}],
  ["pi_lens_activate_tools", { tools: ["ast_grep_search", "lsp_navigation"] }],
  ["lsp_navigation", { operation: "definition" }],
  ["lsp_navigation", { operation: "rename", apply: false }],
  ["lsp_navigation", { operation: "executeCommand", apply: false }],
  ["ast_grep_replace", { apply: false }],
  ["todo", { action: "list" }],
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

it("permits bounded native research delegation without output files", () => {
  const input = { agent: "planning-explore", task: "Inspect the API." };
  expect({
    decision: childPolicy({ toolName: "subagent", input }),
    input,
  }).toStrictEqual({
    decision: undefined,
    input: {
      agent: "planning-explore",
      task: "Inspect the API.",
      async: false,
      output: false,
      options: { context: "fresh", artifacts: false, mission: false },
    },
  });
});

it.each([
  { agent: "worker", task: "Change the project." },
  { agent: "planning-explore", task: "Inspect.", output: "project.ts" },
  { agent: "planning-explore", task: "Inspect.", worktree: true },
  { agent: "planning-explore", task: "Inspect.", async: true },
  {
    agent: "planning-explore",
    task: "Inspect.",
    options: { gate: "touch project.ts" },
  },
  { agent: "planning-explore", task: "Inspect.", options: { sessionDir: "." } },
  { workflow: "run-ci", args: { command: "touch project.ts" } },
  { action: "create", config: { name: "worker" } },
])("rejects unsafe research delegation: %j", (input) => {
  expect(childPolicy({ toolName: "subagent", input })).toMatchObject({
    block: true,
  });
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
  "invalidates an older fresh approval on %s",
  async (action) => {
    const f = fixture();
    await f.command("");
    f.files.replace(f.path(), "# Plan\n");
    f.select.mockResolvedValueOnce("Approve in a fresh conversation");
    await f.execute("submit_plan");
    if (action === "revise") {
      f.select.mockResolvedValueOnce("Revise the plan");
      await f.execute("submit_plan");
    } else {
      await f.command("");
      await f.command("");
    }
    f.controller.settled({ aborted: false });
    expect(f.sendUserMessage).not.toHaveBeenCalled();
  },
);

it("retries the same approval when fresh-session creation fails", async () => {
  const f = fixture();
  await f.command("");
  f.files.replace(f.path(), "# Plan\n");
  f.select.mockResolvedValueOnce("Approve in a fresh conversation");
  await f.execute("submit_plan");
  f.controller.settled({ aborted: false });
  const command = f.sendUserMessage.mock.calls[0]?.[0];
  if (command === undefined) {
    throw new Error("Expected a queued planning handoff");
  }
  vi.mocked(f.ctx.handoff).mockRejectedValueOnce(new Error("fixture failure"));
  await expect(f.command(command.slice("/plan ".length))).rejects.toThrow(
    "fixture failure",
  );
  expect(await f.call("write", { path: "project.ts" })).toMatchObject({
    block: true,
  });
  f.controller.settled({ aborted: false });
  expect(f.sendUserMessage.mock.calls).toStrictEqual([
    ["/plan handoff ticket-1", { expandPromptTemplates: true }],
  ]);
  f.controller.settled({ aborted: true });
  await f.command(command.slice("/plan ".length));
  await f.command(command.slice("/plan ".length));
  expect(
    vi.mocked(f.ctx.handoff).mock.calls.map(([request]) => request.message),
  ).toStrictEqual([
    expect.stringContaining("# Plan"),
    expect.stringContaining("# Plan"),
  ]);
});

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
        data: { version: 1, active, sourceSessionId: "compacted-fork" },
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
