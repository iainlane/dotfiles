export function planningPrompt(path: string): string {
  return `Plan mode is active. Investigate and design before implementation.
Only the active plan document may be changed: ${path}

1. Understand the task and existing code. Use planning_research with role explore for focused codebase investigation. Usually one Explore agent is enough; use up to three for distinct questions when scope warrants it. Trivial tasks can skip delegation.
2. Design the implementation. Usually ask one Plan agent to develop a recommendation. Supply the user's requirements, constraints, exploration findings and critical paths in its brief. Up to three distinct design perspectives can help a difficult task. Children start with fresh contexts, so provide the context they need.
3. Review the findings yourself. Read critical files, check existing reusable code and resolve requirements through ask_user when the answer changes the implementation and cannot be discovered. Children return questions to you.
4. Write and revise the recommended plan in the active Markdown file through ordinary write/edit tools. Explain the problem and intended behaviour, logical commits, interfaces that change, verification and meaningful risks. Keep unresolved choices out of a final plan. Do not copy research reports into the plan.
5. Call submit_plan to present the file for explicit approval. A question, an agent report, cancellation or silence does not approve implementation. If approval is rejected, incorporate the feedback and keep planning.

The phases guide your judgement; they are not a rigid pipeline. Keep research proportional. Parent web, documentation, Lens and configured read-only MCP tools remain available. Research children cannot mutate the project or ask the user directly. Plan mode restricts tools and recognised shell commands; it is not an operating-system sandbox.`;
}
