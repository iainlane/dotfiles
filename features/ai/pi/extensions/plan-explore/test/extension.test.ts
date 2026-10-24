import {
  createEventBus,
  DefaultResourceLoader,
  ExtensionRunner,
  ModelRuntime,
  ModelRegistry,
  SessionManager,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { resolveCurrentSubagentCapabilityCeiling } from "pi-subagents/capability-ceiling";
import { expect, it, vi } from "vitest";
import extension from "../src/extension.ts";

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function rpcRequest(value: unknown) {
  if (!record(value) || typeof value.requestId !== "string") {
    throw new TypeError("Expected a subagent RPC request");
  }

  return {
    requestId: value.requestId,
    method: value.method,
    params: value.params,
  };
}

async function harness() {
  const events = createEventBus();
  const agentDispose = vi.fn<() => void>();
  const agents: unknown[] = [];
  const cwd = "/workspace";
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir: cwd,
    settingsManager: SettingsManager.inMemory(),
    eventBus: events,
    noExtensions: true,
    noSkills: true,
    noThemes: true,
    noPromptTemplates: true,
    noContextFiles: true,
    extensionFactories: [extension],
  });
  events.on("pi-subagents:runtime-agent-register:v1", (request) => {
    if (!record(request)) {
      throw new TypeError("Expected a runtime-agent registration");
    }
    agents.push({ name: request.name, definition: request.definition });
    request.result = { ok: true, registration: { dispose: agentDispose } };
  });

  await loader.reload();

  const models = await ModelRuntime.create({
    authPath: `${cwd}/auth.json`,
    modelsPath: null,
    refreshOnCreate: false,
  });
  const { extensions, runtime } = loader.getExtensions();
  const runner = new ExtensionRunner(
    extensions,
    runtime,
    cwd,
    SessionManager.inMemory(cwd),
    new ModelRegistry(models),
  );
  const ctx = runner.createToolContext("call", undefined);
  const sessionId = ctx.sessionManager.getSessionId();

  await runner.emit({ type: "session_start", reason: "startup" });
  return {
    ctx,
    sessionId,
    events,
    agents,
    agentDispose,
    shutdown: () => runner.emit({ type: "session_shutdown", reason: "quit" }),
    execute(signal?: AbortSignal) {
      const tool = runner.getToolDefinition("plan_explore");
      if (!tool) {
        throw new Error("Expected the exploration tool to be registered");
      }
      return tool.execute(
        "call",
        { task: "Find the configuration parser" },
        signal,
        undefined,
        ctx,
      );
    },
  };
}

it("registers an immutable four-tool exploration agent", async () => {
  const h = await harness();
  expect(h.agents).toStrictEqual([
    {
      name: "plan-explorer",
      definition: {
        description: "Read-only codebase research for implementation plans",
        systemPrompt:
          "Investigate the requested codebase question. Read files and search for relevant definitions, callers and tests. Return concise findings with file paths, line numbers and unresolved questions. Do not implement changes or launch other agents.",
        tools: ["read", "grep", "find", "ls"],
        extensions: [],
        inheritSkills: false,
        allowNestedSubagents: false,
        acceptanceRole: "read-only",
      },
    },
  ]);
  await h.shutdown();
  expect(h.agentDispose).toHaveBeenCalledExactlyOnceWith();
});

it("launches only background exploration under a captured capability ceiling", async () => {
  const h = await harness();
  const launches: unknown[] = [];
  h.events.on("subagents:rpc:v1:request", (raw) => {
    const request = rpcRequest(raw);
    launches.push({
      method: request.method,
      params: request.params,
      ceiling: resolveCurrentSubagentCapabilityCeiling(h.sessionId),
    });
    h.events.emit(`subagents:rpc:v1:reply:${request.requestId}`, {
      version: 1,
      requestId: request.requestId,
      success: true,
      data: {
        text: "Async: plan-explorer [run-id]",
        details: { runId: "run-id" },
      },
    });
  });

  const result = await h.execute();
  expect(launches).toStrictEqual([
    {
      method: "spawn",
      params: {
        agent: "plan-explorer",
        task: "Find the configuration parser",
        cwd: "/workspace",
        context: "fresh",
        async: true,
        worktree: false,
        output: false,
      },
      ceiling: {
        version: 1,
        allowedAgents: ["plan-explorer"],
        allowedTools: ["find", "grep", "ls", "read"],
        denyExtensions: true,
        sources: ["plan-explore"],
      },
    },
  ]);
  expect(result).toStrictEqual({
    content: [{ type: "text", text: "Async: plan-explorer [run-id]" }],
    details: {
      text: "Async: plan-explorer [run-id]",
      details: { runId: "run-id" },
    },
  });
  expect(resolveCurrentSubagentCapabilityCeiling(h.sessionId)).toBeUndefined();
  await h.shutdown();
});

it.each([
  [
    { version: 1, success: false, error: { message: "Unavailable provider" } },
    "Unavailable provider",
  ],
  [{ version: 2, success: true }, "Invalid exploration response"],
])("rejects failed or malformed launch responses", async (reply, message) => {
  const h = await harness();
  h.events.on("subagents:rpc:v1:request", (raw) => {
    const { requestId } = rpcRequest(raw);
    h.events.emit(`subagents:rpc:v1:reply:${requestId}`, {
      ...reply,
      requestId,
    });
  });
  await expect(h.execute()).rejects.toThrow(message);
  expect(resolveCurrentSubagentCapabilityCeiling(h.sessionId)).toBeUndefined();
  await h.shutdown();
});

it("stops a launch acknowledged after cancellation before releasing its ceiling", async () => {
  const h = await harness();
  const controller = new AbortController();
  const stops: unknown[] = [];
  let launchId: string | undefined;
  h.events.on("subagents:rpc:v1:request", (raw) => {
    const request = rpcRequest(raw);
    if (request.method === "spawn") {
      launchId = request.requestId;
      return;
    }
    stops.push(request.params);
    h.events.emit(`subagents:rpc:v1:reply:${request.requestId}`, {
      version: 1,
      requestId: request.requestId,
      success: true,
      data: { state: "stopping" },
    });
  });
  const result = h.execute(controller.signal);
  controller.abort(new Error("cancelled"));
  await Promise.resolve();
  expect(resolveCurrentSubagentCapabilityCeiling(h.sessionId)).toBeDefined();
  h.events.emit(`subagents:rpc:v1:reply:${launchId}`, {
    version: 1,
    requestId: launchId,
    success: true,
    data: {
      text: "Async: plan-explorer [run-id]",
      details: { runId: "run-id" },
    },
  });
  await expect(result).rejects.toThrow("cancelled");
  expect(stops).toStrictEqual([{ id: "run-id" }]);
  expect(resolveCurrentSubagentCapabilityCeiling(h.sessionId)).toBeUndefined();
  await h.shutdown();
});

it("does not launch after cancellation", async () => {
  const h = await harness();
  const launch = vi.fn<(value: unknown) => void>();
  h.events.on("subagents:rpc:v1:request", launch);
  await expect(
    h.execute(AbortSignal.abort(new Error("Cancelled before launch"))),
  ).rejects.toThrow("Cancelled before launch");
  expect(launch).not.toHaveBeenCalled();
  expect(resolveCurrentSubagentCapabilityCeiling(h.sessionId)).toBeUndefined();
  await h.shutdown();
});
