# Planning

Plan an implementation before changing the project. Pi investigates the existing
code, develops an approach, resolves questions and writes a Markdown plan for
review. Focused Explore and Plan agents help the parent understand the code and
assess designs. The parent remains responsible for the final recommendation.

## Starting and reviewing a plan

- `/plan` or Ctrl+Alt+P toggles Plan mode without starting a model turn.
- `/plan <task>` enters Plan mode and starts planning that task.
- `pi --plan` starts a session in Plan mode.
- `/plan review` asks the model to finalise the active draft and request review.

Drafts remain in Pi's agent directory under `plans/` (`~/.pi/agent/plans/` by
default) when Plan mode ends. This follows Pi's `PI_CODING_AGENT_DIR` override.
Returning to the same session preserves the draft. A fork from a planning
session gets its own copy. Reloading, resuming and compaction preserve planning
state.

The model presents the file for approval when the plan is ready. Scroll through
the TUI review with arrow or page keys, then choose:

- `a`: approve implementation in the current conversation.
- `f`: approve implementation in a fresh conversation containing the plan and a
  reference to the source conversation.
- `r`: request revisions.
- Escape: cancel review and continue planning.

RPC clients receive the same choices through Pi's dialog protocol. Approval
applies to the displayed revision. If the file changes during review, Pi asks
for another review. Cancelling a dialog or answering a question does not approve
implementation. Toggling Plan mode off preserves the draft and ends the tool
restrictions; it does not record plan approval.

## Investigation and questions

Inspect known targets directly. Use Explore to locate code, tests and evidence
for a broad investigation. Use Plan to assess non-trivial implementation
approaches, trade-offs, reuse and verification. Both roles are available through
`planning_research`; the parent supplies a focused brief with requirements,
constraints and prior findings for each fresh context. Up to three distinct
investigations can run concurrently.

Research children can delegate focused subtasks to either planning role through
`subagent` with `async:false`. Descendants inherit the research restrictions,
required policy extension and runtime depth and fan-out limits. The deployment
permits two levels of research agents. Reports return through tool results;
research agents cannot edit project files or the parent's plan.

The general `ask_user` tool remains available to the parent, including outside
Plan mode. Children return unresolved questions to the parent. The parent writes
the final plan and requests approval through `submit_plan`. Pure research can
finish with findings without submitting an implementation plan.

Planning guidance is refreshed when a new run starts. Concise reminders are
added after five completed turns and after compaction.

## Tool restrictions

The parent and research descendants can read and search, use Lens, consult the
web and call configured read-only MCP tools. Web and Lens activation tools are
permitted. LSP navigation and AST rewrites are available as read-only operations
or edit previews; applying changes remains blocked. The parent can use ordinary
`write` and `edit` calls for the active plan only. Nested codemode calls receive
the same checks.

`planning.json` specifies trusted `readOnlyTools`, raw `mcpDirectTools`
selectors and the `researchExtensions` to load in children. MCP annotations
alone do not grant planning access. Tool identifiers use Pi's normalised form;
MCP selectors use the server's original tool identifiers, such as
`context7/resolve-library-id`.

Recognised shell inspections run with potentially executable Git helpers
disabled. Known mutations are blocked. An unclassified parent command requires
explicit permission for that command; research children must return the
investigation to the parent. Command permission does not approve the plan.

These are tool and command policies, not an operating-system sandbox. The
policies trust the configured shell, executable resolution, inherited
environment and extension implementations. Changing shell prefixes or replacing
tools changes that boundary.

## Validation

The Nix package checks types and lint rules against the declared development
dependencies, then runs tests with the deployed `pi-subagents` package. That
package includes the child-runtime registration patch required for nested
planning roles. For local npm checks, set `PI_TEST_SUBAGENTS` to that package's
root. Native tests exercise web and Lens activation, selected MCP tools,
inherited restrictions and the delegation depth limit.
