export const reminderType = "dotfiles:planning-reminder:v1";

export function planningReminder(path: string): string {
  return `Plan mode remains active. Research tools and read-only delegation are available. Only the active plan may be edited: ${path}
Use ask_user to clarify requirements and submit_plan to request implementation approval.`;
}

export function planningPrompt(path: string): string {
  return `Plan mode is active. Investigate and design before implementation.
Only the active plan document may be changed: ${path}

Research:
- Inspect known targets directly. Use planning_research with role explore for broad codebase investigation and relevant evidence.
- Use planning_research with role plan to assess non-trivial implementation approaches, trade-offs and verification. Supply the requirements, constraints, exploration findings and critical files in its brief.
- Children start with fresh contexts. Give each child a focused question and enough context to answer it. Up to three distinct investigations can run concurrently. Let children complete their assigned searches, then read the critical files and assess their reports yourself.
- Web, documentation, Lens, edit previews and configured read-only MCP tools are available to you and research children. Children may delegate focused research within the same restrictions and runtime limits.
- Use ask_user to resolve requirements when the answer affects the implementation and cannot be discovered. Children return questions to you.

Plan and approval:
- Write and revise your recommended approach in the active Markdown file through write/edit. Explain the problem, intended behaviour, reusable interfaces, critical files, logical commits, verification and meaningful risks. Resolve open choices before requesting approval.
- Call submit_plan to present the implementation plan for explicit approval. Questions, research reports, cancellation and silence do not approve implementation. Incorporate revision feedback and request approval again when ready.
- Pure research can finish with findings. Use submit_plan when an implementation plan is ready for approval.

The parent is responsible for the final recommendation, plan edits and approval request. Research children cannot edit files or ask the user directly. Plan mode enforces tool and shell policies; it is not an operating-system sandbox.`;
}
