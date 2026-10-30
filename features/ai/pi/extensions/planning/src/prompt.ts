import type { PlanRevision } from "./store.ts";

export const reminderType = "dotfiles:planning-reminder:v1";
export const exitReminderType = "dotfiles:planning-exit:v1";
export const clearContextType = "dotfiles:planning-clear:v1";

export function planExitReminder(path: string): string {
  return `Plan mode has ended. Plan file: ${path}
Use the normal file tools to read or update the plan. Follow the user's current request; leaving Plan mode does not itself approve implementation.`;
}

export function attachedPlanContext(plan: PlanRevision): string {
  return `A plan file is attached to this conversation: ${plan.path}
Current revision: ${plan.revision}

Plan contents:
${plan.content}
Use this plan if it is relevant to the user's current request and not already complete. This context does not grant implementation approval.`;
}

export function implementationContext(
  plan: PlanRevision,
  source: string,
): string {
  return `Plan mode has ended. Implement this approved plan.

Plan file: ${plan.path}
Approved revision: ${plan.revision}
Planning transcript: ${source}

${plan.content}`;
}

export function planningReminder(path: string): string {
  return `Plan mode remains active. Research tools and read-only delegation are available. Only the active plan may be edited: ${path}
Use ask_user to clarify requirements and submit_plan to request implementation approval.`;
}

export function planningPrompt(path: string): string {
  return `Plan mode is active. Investigate and design before implementation.
Only the active plan document may be changed: ${path}

Research:
- Inspect known targets directly. Use subagent with agent planning-explore for broad codebase investigation and relevant evidence.
- Use subagent with agent planning-plan to assess non-trivial implementation approaches, trade-offs and verification. Supply the requirements, constraints, exploration findings and critical files in its task.
- Planning agents start with fresh contexts and run in the background by default. Use async:false when you must wait for a result. Enable the normal subagent tools with subagents_enable if needed. Give each child a focused question and enough context to answer it. Continue independent investigation while children run, then use their native completion notifications and status or cancellation controls. Read the critical files and assess the reports yourself.
- Web, documentation, Lens, edit previews and configured read-only MCP tools are available to you and research children. Children may delegate focused research within the same restrictions and runtime limits.
- Use ask_user to resolve requirements when the answer affects the implementation and cannot be discovered. Children return questions to you.

Plan and approval:
- Write and revise your recommended approach in the active Markdown file through write/edit. Explain the problem, intended behaviour, reusable interfaces, critical files, logical commits, verification and meaningful risks. Resolve open choices before requesting approval.
- Wait for active subagents to finish or cancel them before calling submit_plan. Call submit_plan to present the implementation plan for explicit approval. Questions, research reports, cancellation and silence do not approve implementation. Incorporate revision feedback and request approval again when ready.
- Pure research can finish with findings. Use submit_plan when an implementation plan is ready for approval.

The parent is responsible for the final recommendation, plan edits and approval request. Research children cannot edit files or ask the user directly. Plan mode enforces tool and shell policies; it is not an operating-system sandbox.`;
}
