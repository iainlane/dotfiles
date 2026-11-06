import type { PlanRevision } from "./store.ts";

export const planDisplayType = "dotfiles:planning-display:v1";
export const reminderType = "dotfiles:planning-reminder:v1";
export const exitReminderType = "dotfiles:planning-exit:v1";
export const clearContextType = "dotfiles:planning-clear:v1";
export const implementationMessageType = "dotfiles:planning-implementation:v1";

export const enterPlanDescription = `Use this tool when a non-trivial implementation task needs agreement on significant design choices. Agree on the approach with the user before writing code so the user can correct design choices before you implement them. This tool requests permission to enter read-only Plan mode, where you can explore the codebase and design an implementation approach for user approval.

## When to Use This Tool

**Prefer using enter_plan_mode** for non-trivial implementation tasks with significant unresolved design choices, or when the user requests planning. Inspect relevant code first. The following situations can warrant planning; they are not automatic entry triggers. Investigation, file count and focused clarification alone do not require Plan mode.

1. **New Feature Implementation**: Adding meaningful new functionality
   - Example: "Add a logout button" - where should it appear? What should happen on click?
   - Example: "Add form validation" - what rules and error messages should apply?

2. **Multiple Valid Approaches**: The task can be solved in several different ways
   - Example: "Add caching to the API" - Redis, in-memory or file-based caching could work
   - Example: "Improve performance" - several optimisation strategies are possible

3. **Code Modifications**: Changes significantly affect existing behaviour or architecture
   - Example: "Update the login flow" - what should change?
   - Example: "Refactor this component" - what is the target architecture?

4. **Architectural Decisions**: The task requires choosing between patterns or technologies
   - Example: "Add real-time updates" - WebSockets, SSE or polling?
   - Example: "Implement state management" - Redux, Context or a custom solution?

5. **Multi-File Changes**: Changes span components and require agreement on interfaces or sequencing
   - Example: "Refactor the authentication system"
   - Example: "Add a new API endpoint with tests"

6. **Unclear Requirements**: Investigation reveals unresolved scope or requirements that affect the design
   - Example: "Make the app faster" - profile and identify bottlenecks first
   - Example: "Fix the bug in checkout" - investigate the root cause first

7. **User Preferences Matter**: The implementation could reasonably go in several directions
   - Use ask_user directly for a focused clarification; use enter_plan_mode when the choice requires a broader design discussion
   - Plan mode lets you explore first, then present options with context

## When NOT to Use This Tool

Skip enter_plan_mode for these tasks:
- Single-line or few-line fixes, such as typos, obvious bugs or small tweaks
- Adding a single function with clear requirements
- Bounded fixes and small features with clear requirements, including their tests
- Tasks where the user has given very specific, detailed instructions
- Pure research or exploration tasks (use subagent instead when delegation is authorised)

## What Happens in Plan Mode

In Plan mode, you will:
1. Explore the codebase using the available read-only tools
2. Understand existing patterns and architecture
3. Design an implementation approach
4. Write the recommended approach in the active Markdown plan file
5. Use ask_user if you need to clarify approaches
6. Use submit_plan to present your plan for explicit implementation approval

Only the active plan file may be edited. Do not change project files during planning.

## Examples

### GOOD - Use enter_plan_mode:
User: "Add user authentication to the app"
- Requires architectural decisions about sessions or JWT, token storage and middleware

User: "Optimise the database queries"
- Several approaches are possible; profile first and assess the impact

User: "Implement dark mode"
- Requires an architectural decision about the theme system and affects several components

User: "Add a delete button to the user profile"
- Requires agreement on placement, confirmation and API behaviour not established by existing patterns

User: "Update the error handling in the API"
- Changes error semantics across the API; the user should approve the approach

### BAD - Do not use enter_plan_mode:
User: "Fix the typo in the README"
- Straightforward; no planning is needed

User: "Add a console.log to debug this function"
- A simple, obvious implementation

User: "What files handle routing?"
- Research, not implementation planning

## Important Notes

- This tool requires user consent before entering Plan mode. If Plan mode is inactive, calling it opens Pi's entry confirmation.
- If unsure, investigate the relevant code first. Proceed directly when the task is bounded and the intended behaviour is clear.
- Entry consent does not approve implementation. The completed plan requires separate approval through submit_plan.
`;

export const submitPlanDescription = `Use this tool when an implementation plan is ready for explicit user approval. Write the complete plan to the active Markdown file before calling it. Begin with Context, then describe the recommended approach, critical files, reusable interfaces and verification. Explain sequencing and risks when they matter. Resolve questions with the user and finish or cancel active research first.

This tool presents the actual saved document. Approval applies only to the reviewed revision. Questions through ask_user, displaying or editing a plan, leaving Plan mode and silence do not approve implementation. Incorporate revision feedback and submit again when ready. Call submit_plan directly, outside codemode. Pure research can finish with findings without requesting implementation approval.`;

export function planExitReminder(path?: string): string {
  const plan =
    path === undefined
      ? ""
      : ` Plan file: ${path}\nUse the normal file tools to read or update the plan.`;
  return `## Exited Plan Mode\n\nYou have exited plan mode.${plan} Follow the user's current request; leaving Plan mode does not itself approve implementation.`;
}

export function attachedPlanContext(plan: PlanRevision): string {
  return `A plan file is attached to this conversation: ${plan.path}
Current revision: ${plan.revision}

Plan contents:
${plan.content}
Use this plan if it is relevant to the user's current request and not already complete. This context does not grant implementation approval.`;
}

export function reviewedPlanContext(plan: PlanRevision): string {
  return `Reviewed plan:
Plan file: ${plan.path}
Reviewed revision: ${plan.revision}

${plan.content}`;
}

export function implementationContext(
  plan: PlanRevision,
  source: string,
  feedback?: string,
): string {
  return `Plan mode has ended. Implement this approved plan.

Plan file: ${plan.path}
Approved revision: ${plan.revision}
Planning transcript: ${source}

${plan.content}${feedback === undefined ? "" : `\n\n${reviewFeedbackContext(feedback)}`}`;
}

export function reviewFeedbackContext(feedback: string): string {
  return `User feedback:\n${feedback}`;
}

export function planningReminder(path: string): string {
  return `Plan mode remains active. Research tools and read-only delegation are available. Only the active plan may be edited: ${path}
Use ask_user to clarify requirements and submit_plan to request implementation approval.`;
}

export function planningPrompt(path: string, existingPlan = false): string {
  return `Plan mode is active. Investigate and design before implementation.
Only the active plan document may be changed: ${path}

Research:
- Inspect known targets directly. Use subagent with agent planning-explore for broad codebase investigation and relevant evidence.
- Use subagent with agent planning-plan to assess non-trivial implementation approaches, trade-offs and verification. Supply the requirements, constraints, exploration findings and critical files in its task.
- Planning agents start with fresh contexts and run in the background by default. Use async:false when you must wait for a result. Enable the normal subagent tools with subagents_enable if needed. Give each child a focused question and enough context to answer it. Continue independent investigation while children run, then use their native completion notifications and status or cancellation controls. Read the critical files and assess the reports yourself.
- Web, documentation, Lens, edit previews and normal native MCP discovery are available to you and research children. Shell and MCP calls follow the host's normal permissions without planning-specific classification or restrictions. Children may delegate focused research within the same planning guards and runtime limits.
- Use ask_user to resolve requirements when the answer affects the implementation and cannot be discovered. Children return questions to you.

Plan and approval:
- Write and revise your recommended approach in the active Markdown file through write/edit. Begin with Context to explain the problem and intended behaviour. Describe the recommended approach, reusable interfaces, critical files and verification. Explain sequencing and meaningful risks when they matter. Resolve open choices before requesting approval.
- Wait for active subagents to finish or cancel them before calling submit_plan. Call submit_plan to present the implementation plan for explicit approval. Questions, research reports, cancellation and silence do not approve implementation. Incorporate revision feedback and request approval again when ready.
- Pure research can finish with findings. Use submit_plan when an implementation plan is ready for approval.

The parent is responsible for the final recommendation, plan edits and approval request. Research children must not edit files or ask the user directly. Ordinary file edits and mutation previews have planning guards; shell and MCP execution follows native policy. Plan mode is not an operating-system sandbox.${existingPlan ? `\n\nExisting plan:\nA plan file already exists at ${path}. Read it and compare it with the user's current request.\n- If this is a different task, overwrite the old plan with a new one.\n- If this continues the same task, update the plan and remove obsolete details.\nDo not assume the old plan still applies. Update the plan file before requesting approval.` : ""}`;
}
