import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  registerAgentViaEvents,
  type RuntimeAgentRegistration,
} from "pi-subagents/agents";
import { registerSubagentCapabilityCeiling } from "pi-subagents/capability-ceiling";
import { Type } from "typebox";
import { requestExploration } from "./rpc.ts";

const agentName = "plan-explorer";
const tools = ["read", "grep", "find", "ls"];

export default function extension(pi: ExtensionAPI) {
  let agent: RuntimeAgentRegistration | undefined;

  pi.on("session_start", () => {
    agent?.dispose();
    agent = registerAgentViaEvents({
      pi,
      name: agentName,
      definition: {
        description: "Read-only codebase research for implementation plans",
        systemPrompt:
          "Investigate the requested codebase question. Read files and search for relevant definitions, callers and tests. Return concise findings with file paths, line numbers and unresolved questions. Do not implement changes or launch other agents.",
        tools,
        extensions: [],
        inheritSkills: false,
        allowNestedSubagents: false,
        acceptanceRole: "read-only",
      },
    });
  });

  pi.on("session_shutdown", () => {
    agent?.dispose();
    agent = undefined;
  });

  pi.registerTool({
    name: "plan_explore",
    label: "Explore for Planning",
    description:
      "Launch a background codebase research subagent with only read, grep, find and ls. Returns a launch receipt; findings arrive through the normal subagent completion notification. No shell, file-writing, MCP or nested delegation tools are available.",
    promptSnippet:
      "Use plan_explore for bounded read-only codebase research that will inform a /plan implementation plan. Planning research delegation is authorised; keep each task specific and synthesise the findings in the parent.",
    parameters: Type.Object(
      {
        task: Type.String({ minLength: 1, maxLength: 16000 }),
      },
      { additionalProperties: false },
    ),
    async execute(_id, { task }, signal, _onUpdate, ctx) {
      signal?.throwIfAborted();
      if (!agent) {
        throw new Error("Reload Pi before launching planning exploration.");
      }

      const restriction = registerSubagentCapabilityCeiling({
        sessionId: ctx.sessionManager.getSessionId(),
        source: "plan-explore",
        ceiling: {
          allowedAgents: [agentName],
          allowedTools: tools,
          denyExtensions: true,
        },
      });

      try {
        const result = await requestExploration(
          pi.events,
          {
            agent: agentName,
            task,
            cwd: ctx.cwd,
            context: "fresh",
            async: true,
            worktree: false,
            output: false,
          },
          signal,
        );

        return {
          content: [{ type: "text", text: result.text }],
          details: result,
        };
      } finally {
        restriction.dispose();
      }
    },
  });
}
