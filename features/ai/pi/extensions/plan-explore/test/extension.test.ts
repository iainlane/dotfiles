import type {
  ExtensionAPI,
  ExtensionContext,
  ExtensionToolContext,
  ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { createEventBus } from "@earendil-works/pi-coding-agent";
import type { RuntimeAgentRegistrationRequest } from "pi-subagents/agents";
import { resolveCurrentSubagentCapabilityCeiling } from "pi-subagents/capability-ceiling";
import { expect, it, vi } from "vitest";
import extension from "../src/extension.ts";

type Handler = (event: unknown, ctx: ExtensionContext) => unknown;

function harness() {
  const handlers = new Map<string, Handler>();
  const events = createEventBus();
  const agentDispose = vi.fn();
  const agents: unknown[] = [];
  let tool: ToolDefinition | undefined;
  const ctx = {
    cwd: "/workspace",
    sessionManager: { getSessionId: () => "plan-explore-test" },
  } as unknown as ExtensionToolContext;
  const pi = {
    events,
    on(name: string, callback: Handler) {
      handlers.set(name, callback);
    },
    registerTool(definition: ToolDefinition) {
      tool = definition;
    },
  } as unknown as ExtensionAPI;
  events.on("pi-subagents:runtime-agent-register:v1", (value) => {
    const request = value as RuntimeAgentRegistrationRequest;
    agents.push({ name: request.name, definition: request.definition });
    request.result = { ok: true, registration: { dispose: agentDispose } };
  });
  extension(pi);
  handlers.get("session_start")?.({}, ctx);

  return {
    ctx,
    events,
    agents,
    agentDispose,
    shutdown: () => handlers.get("session_shutdown")?.({}, ctx),
    execute(signal?: AbortSignal) {
      if (!tool)
        throw new Error("Expected the exploration tool to be registered");
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

it("registers an immutable four-tool exploration agent", () => {
  const h = harness();
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
  h.shutdown();
  expect(h.agentDispose).toHaveBeenCalledExactlyOnceWith();
});

it("launches only background exploration under a captured capability ceiling", async () => {
  const h = harness();
  const launches: unknown[] = [];
  h.events.on("subagents:rpc:v1:request", (raw) => {
    const request = raw as {
      requestId: string;
      params: unknown;
      method: string;
    };
    launches.push({
      method: request.method,
      params: request.params,
      ceiling: resolveCurrentSubagentCapabilityCeiling("plan-explore-test"),
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
  expect(
    resolveCurrentSubagentCapabilityCeiling("plan-explore-test"),
  ).toBeUndefined();
  h.shutdown();
});

it.each([
  [
    { version: 1, success: false, error: { message: "Unavailable provider" } },
    "Unavailable provider",
  ],
  [{ version: 2, success: true }, "Invalid exploration response"],
])("rejects failed or malformed launch responses", async (reply, message) => {
  const h = harness();
  h.events.on("subagents:rpc:v1:request", (raw) => {
    const { requestId } = raw as { requestId: string };
    h.events.emit(`subagents:rpc:v1:reply:${requestId}`, {
      ...reply,
      requestId,
    });
  });
  await expect(h.execute()).rejects.toThrow(message);
  expect(
    resolveCurrentSubagentCapabilityCeiling("plan-explore-test"),
  ).toBeUndefined();
  h.shutdown();
});

it("stops a launch acknowledged after cancellation before releasing its ceiling", async () => {
  const h = harness();
  const controller = new AbortController();
  const stops: unknown[] = [];
  let launchId: string | undefined;
  h.events.on("subagents:rpc:v1:request", (raw) => {
    const request = raw as {
      requestId: string;
      method: string;
      params: unknown;
    };
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
  const result = expect(h.execute(controller.signal)).rejects.toThrow(
    "cancelled",
  );
  controller.abort(new Error("cancelled"));
  await Promise.resolve();
  expect(
    resolveCurrentSubagentCapabilityCeiling("plan-explore-test"),
  ).toBeDefined();
  h.events.emit(`subagents:rpc:v1:reply:${launchId}`, {
    version: 1,
    requestId: launchId,
    success: true,
    data: {
      text: "Async: plan-explorer [run-id]",
      details: { runId: "run-id" },
    },
  });
  await result;
  expect(stops).toStrictEqual([{ id: "run-id" }]);
  expect(
    resolveCurrentSubagentCapabilityCeiling("plan-explore-test"),
  ).toBeUndefined();
  h.shutdown();
});

it("does not launch after cancellation", async () => {
  const h = harness();
  const launch = vi.fn();
  h.events.on("subagents:rpc:v1:request", launch);
  await expect(h.execute(AbortSignal.abort())).rejects.toThrow();
  expect(launch).not.toHaveBeenCalled();
  expect(
    resolveCurrentSubagentCapabilityCeiling("plan-explore-test"),
  ).toBeUndefined();
  h.shutdown();
});
