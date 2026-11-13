import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerAgentViaEvents } from "pi-subagents/agents";
import { afterEach, expect, it, vi } from "vitest";
import { Type } from "typebox";
import { registerPlanningRoles } from "#planning/roles.ts";

vi.mock("pi-subagents/agents", () => ({
  registerAgentViaEvents: vi.fn<typeof registerAgentViaEvents>(() => ({
    dispose: vi.fn<() => void>(),
  })),
}));

afterEach(() => vi.clearAllMocks());

it.each([
  {
    role: "planning-explore",
    pattern:
      /file search specialist.*Your strengths:.*Guidelines:.*find.*grep.*read.*thoroughness.*parallel.*report/s,
  },
  {
    role: "planning-plan",
    pattern:
      /software architect and planning specialist.*Understand Requirements.*Explore Thoroughly.*Design Solution.*Detail the Plan.*Critical Files for Implementation/s,
  },
])("describes the research process for $role", ({ role, pattern }) => {
  registerPlanningRoles(
    { getAllTools: () => [], events: { emit() {}, on: () => () => {} } },
    {},
  );
  const request = vi
    .mocked(registerAgentViaEvents)
    .mock.calls.find(([input]) => input.name === role)?.[0];

  expect(request?.definition.systemPrompt).toMatch(pattern);
});

it("requires stable research tools without copying dynamic MCP resources or parent-only tools", () => {
  const names = [
    "read",
    "codemode",
    "tool_search",
    "list_mcp_resources",
    "list_mcp_resource_templates",
    "read_mcp_resource",
    "write",
    "edit",
    "ask_user",
    "submit_plan",
    "enter_plan_mode",
    "unrelated_extension_tool",
  ];
  const pi: Pick<ExtensionAPI, "getAllTools" | "events"> = {
    getAllTools: () =>
      names.map((name) => ({
        name,
        description: "Offline parent tool fixture.",
        parameters: Type.Object({}),
        exposure: "direct",
        sourceInfo: {
          path: "fixture",
          source: "extension",
          scope: "temporary",
          origin: "top-level",
        },
      })),
    events: { emit() {}, on: () => () => {} },
  };
  registerPlanningRoles(pi, {});

  expect(
    vi.mocked(registerAgentViaEvents).mock.calls.map(([request]) => ({
      name: request.name,
      tools: request.definition.tools,
    })),
  ).toStrictEqual(
    ["planning-explore", "planning-plan"].map((name) => ({
      name,
      tools: ["read", "codemode", "tool_search", "bash", "subagent"],
    })),
  );
});

it("leaves research deadlines to native pi-subagents defaults", () => {
  const pi: Pick<ExtensionAPI, "getAllTools" | "events"> = {
    getAllTools: () => [],
    events: { emit() {}, on: () => () => {} },
  };
  registerPlanningRoles(pi, {});

  expect(
    vi.mocked(registerAgentViaEvents).mock.calls.map(([request]) => ({
      name: request.name,
      timeout: request.definition.defaultTimeoutMs,
      async: request.definition.defaultAsync,
      model: request.definition.model,
    })),
  ).toStrictEqual([
    {
      name: "planning-explore",
      timeout: undefined,
      async: true,
      model: "inherit",
    },
    {
      name: "planning-plan",
      timeout: undefined,
      async: true,
      model: "inherit",
    },
  ]);
});
