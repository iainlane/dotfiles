import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  registerAgentViaEvents,
  type RuntimeAgentRegistration,
} from "pi-subagents/agents";
import { researchTools } from "./child.ts";

const prompts = {
  explore:
    "Investigate the parent's specific codebase question. Locate relevant definitions, callers, tests and reusable patterns. Read enough context to distinguish evidence from inference. Return concise findings with paths and line numbers, limitations and questions for the parent. Do not implement changes, ask the user directly or delegate.",
  plan: "Design an implementation from the parent's requirements and research brief. Inspect the critical files, verify existing patterns and identify reuse. Consider trade-offs, dependencies, edge cases and verification. Return a recommended approach and logical implementation steps, with unresolved questions for the parent. Do not implement changes, write the parent's final plan, ask the user directly or delegate.",
};

export function registerPlanningRoles(
  pi: ExtensionAPI,
): RuntimeAgentRegistration[] {
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
                ? "Codebase exploration for a plan"
                : "Implementation design from a research brief",
            systemPrompt: prompts[role],
            model: "inherit",
            defaultContext: "fresh",
            defaultAsync: false,
            tools: researchTools,
            inheritSkills: false,
            inheritGlobalContext: false,
            inheritProjectContext: true,
            extensions: [],
            allowNestedSubagents: false,
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
