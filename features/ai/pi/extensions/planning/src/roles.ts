import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  registerAgentViaEvents,
  type RuntimeAgentRegistration,
} from "pi-subagents/agents";
import { researchReaders } from "./policy.ts";
import type { PlanningSettings } from "./settings.ts";

const prompts = {
  explore:
    "Investigate the parent's focused codebase question. Locate relevant definitions, callers, tests and reusable interfaces. Read enough surrounding code to establish the relationships. Return concise findings with paths and line ranges, supporting evidence, unexamined areas and unresolved questions. Distinguish observed facts from inference.",
  plan: "Assess an implementation approach from the parent's requirements and research brief. Read the critical files and verify existing patterns. Consider alternatives, reusable interfaces, dependencies, edge cases and verification. Return a recommended design with trade-offs, logical implementation steps, critical file paths and unresolved questions for the parent.",
};
const researchInstructions = `Use the available file, code-navigation, web and documentation tools. Run independent inspections in parallel where useful. You may delegate focused research to planning-explore or planning-plan with subagent({agent, task}); descendants inherit the same read-only restrictions and runtime limits. Background execution is the default; use async:false when you must wait for a result. Continue independent investigation while background jobs run. Use native status and cancellation controls, and collect descendant results with bg_wait before returning your report; child runtimes have no automatic completion notifier. Supply the requirements and relevant findings in each fresh-context brief.
Return your report directly in your response. The parent writes the final plan, asks the user questions and requests approval. Do not edit files or begin implementation.`;

export function registerPlanningRoles(
  pi: ExtensionAPI,
  settings: PlanningSettings,
): RuntimeAgentRegistration[] {
  const available = new Set(pi.getAllTools().map((tool) => tool.name));
  const tools = [
    ...new Set([
      ...researchReaders,
      ...settings.readOnlyTools.filter((tool) => !tool.startsWith("mcp__")),
    ]),
  ].filter((tool) => available.has(tool));
  const registrations: RuntimeAgentRegistration[] = [];
  try {
    for (const role of ["explore", "plan"] as const) {
      registrations.push(
        registerAgentViaEvents({
          pi,
          name: `planning-${role}`,
          definition: {
            description:
              role === "explore"
                ? "Locate relevant code, tests and evidence for a focused research question"
                : "Assess implementation designs, trade-offs, reuse and verification",
            systemPrompt: `${prompts[role]}\n\n${researchInstructions}`,
            model: "inherit",
            defaultContext: "fresh",
            defaultAsync: true,
            defaultTimeoutMs: 300_000,
            tools: [...tools, "bash", "subagent"],
            mcpDirectTools: settings.mcpDirectTools,
            inheritSkills: false,
            inheritGlobalContext: false,
            inheritProjectContext: true,
            extensions: settings.researchExtensions ?? [],
            allowNestedSubagents: true,
            acceptanceRole: "read-only",
          },
        }),
      );
    }
    return registrations;
  } catch (error) {
    for (const registration of registrations) {
      registration.dispose();
    }
    throw error;
  }
}
