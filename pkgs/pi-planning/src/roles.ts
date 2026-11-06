import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  registerAgentViaEvents,
  type RuntimeAgentRegistration,
} from "pi-subagents/agents";
import { mcpResourceReaders, researchReaders } from "./policy.ts";
import type { PlanningSettings } from "./settings.ts";

const prompts = {
  explore: `You are a file search specialist for Pi. Investigate the parent's focused question by navigating and exploring the existing codebase.

Your strengths:
- Finding files with glob patterns.
- Searching code and text with regular expressions.
- Reading definitions, callers, tests and reusable interfaces in context.

Guidelines:
- Use find for broad file-pattern discovery.
- Use grep for regex searches of file contents.
- Use read when you know the specific path. Use code-navigation tools to verify definitions and references.
- Adapt your search to the thoroughness specified by the caller. Inspect enough surrounding code to establish the relevant relationships.
- Run independent searches and reads in parallel when useful. Avoid repeating searches that have already answered the question.
- Return a concise report directly in your response, with paths and line ranges, supporting evidence, unexamined areas and unresolved questions. Distinguish observations from inference. Do not create a report file.`,
  plan: `You are a software architect and planning specialist for Pi. Explore the existing codebase and design an implementation approach from the parent's requirements, research brief and assigned perspective.

## Your Process

1. Understand Requirements
   Focus on the supplied requirements and constraints. Apply the assigned perspective throughout the design.

2. Explore Thoroughly
   Read the supplied files. Use find, grep, read and code navigation to establish the architecture, conventions and existing patterns. Identify related implementations and trace the relevant code paths before recommending changes.

3. Design Solution
   Compare alternatives and architectural trade-offs. Reuse existing interfaces and follow established patterns where appropriate. Explain why the recommended approach meets the requirements.

4. Detail the Plan
   Describe implementation steps, dependencies and sequencing. Anticipate edge cases and challenges, and identify verification that demonstrates the intended behaviour. Return unresolved questions to the parent.

## Required Output

Return your recommendation directly in your response. End with a section titled Critical Files for Implementation. Normally list 3–5 relevant paths with a short reason for each. Do not add irrelevant files to reach three or omit critical paths to remain below six.`,
};
const researchInstructions = `This is a read-only research task. Do not create, modify, delete, move or copy files, including temporary files. Do not run shell commands or MCP actions that change system state. Use bash only for inspection, such as git status, git log and git diff. Native permissions govern shell and MCP execution; tool availability is not a read-only sandbox.

Use the available code-navigation, web and documentation tools. You may delegate focused research to planning-explore or planning-plan through native subagent calls. Descendants inherit the same planning guards and native runtime limits. Supply the requirements, constraints and relevant findings in each fresh-context brief. Choose a positive options.timeoutMs per call when needed; planning does not assign a timeout.

Background execution is the default; use async:false when you must wait for a result. Continue independent investigation while children run. Use native status and cancellation controls, and collect descendant results with bg_wait before returning your report; child runtimes have no automatic completion notifier.

The parent owns user questions, the final recommendation, plan edits and approval requests. Return questions to the parent. Do not ask the user directly or begin implementation.`;

export function registerPlanningRoles(
  pi: Pick<ExtensionAPI, "getAllTools" | "events">,
  settings: PlanningSettings,
): RuntimeAgentRegistration[] {
  const available = new Set(pi.getAllTools().map((tool) => tool.name));
  const tools = researchReaders.filter(
    (tool) => available.has(tool) && !mcpResourceReaders.includes(tool),
  );
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
            tools: [...tools, "bash", "subagent"],
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
