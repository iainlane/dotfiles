import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { RUNTIME_AGENT_REGISTER_EVENT } from "pi-subagents/agents";
import { expect, it } from "vitest";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { registerPlanningRoles } from "#planning/roles.ts";

const registrationSchema = Type.Object({
  name: Type.String(),
  definition: Type.Record(Type.String(), Type.Unknown()),
  result: Type.Optional(Type.Unknown()),
});

// Answers runtime agent registrations as the installed pi-subagents runtime
// does, and keeps the registered agents.
function subagentRuntime(tools: string[] = []) {
  const agents = new Map<string, Record<string, unknown>>();
  const pi: Pick<ExtensionAPI, "getAllTools" | "events"> = {
    getAllTools: () =>
      tools.map((name) => ({
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
    events: {
      emit(channel, data) {
        if (
          channel !== RUNTIME_AGENT_REGISTER_EVENT ||
          !Check(registrationSchema, data)
        ) {
          return;
        }
        agents.set(data.name, data.definition);
        data.result = {
          ok: true,
          registration: {
            dispose: () => {
              agents.delete(data.name);
            },
          },
        };
      },
      on: () => () => {},
    },
  };
  return { pi, agents };
}

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
  const runtime = subagentRuntime();
  registerPlanningRoles(runtime.pi, {});

  expect(runtime.agents.get(role)?.systemPrompt).toMatch(pattern);
});

it("requires stable research tools without copying dynamic MCP resources or parent-only tools", () => {
  const runtime = subagentRuntime([
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
  ]);
  registerPlanningRoles(runtime.pi, {});

  expect(
    [...runtime.agents].map(([name, definition]) => ({
      name,
      tools: definition.tools,
    })),
  ).toStrictEqual(
    ["planning-explore", "planning-plan"].map((name) => ({
      name,
      tools: ["read", "codemode", "tool_search", "bash", "subagent"],
    })),
  );
});

it("leaves research deadlines to native pi-subagents defaults", () => {
  const runtime = subagentRuntime();
  registerPlanningRoles(runtime.pi, {});

  expect(
    [...runtime.agents].map(([name, definition]) => ({
      name,
      timeout: definition.defaultTimeoutMs,
      async: definition.defaultAsync,
      model: definition.model,
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
