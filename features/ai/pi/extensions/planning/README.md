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

The model presents the file for approval when the plan is ready. The complete
plan appears in Pi's transcript, with an approval question in the fixed editor
dock. In fullscreen mode, scroll with the wheel or Page Up/Down. In regular
mode, use the terminal's scrollback. Use Up/Down and Enter to choose, or press:

- `a`: approve implementation in the current conversation.
- `c`: approve implementation and clear the conversation context.
- `r`: request revisions.
- Escape: cancel review and continue planning.

Ctrl+G opens the actual plan file in your editor. This uses Pi's configurable
`app.editor.external` keybinding and the effective `externalEditor` setting,
then `VISUAL`, `EDITOR`, or Pi's platform default. Quoted executable paths and
literal arguments are supported; use a wrapper script for shell constructs. GUI
editors need a wait-capable command such as `code --wait`. After the editor
returns, Pi rereads and displays the saved revision. Editing does not approve
the plan; approve the updated version explicitly.

`submit_plan` is a direct model interaction, so call it outside codemode. Its
final tool result retains the displayed snapshot for transcript reconstruction.

RPC clients receive the same choices through Pi's dialogue protocol. Approval
applies to the displayed revision. If the file changes during review, Pi asks
for another review. Cancelling a dialogue or answering a question does not
approve implementation. Toggling Plan mode off preserves the draft and ends the
tool restrictions; it does not record plan approval.

## Implementation context

Clearing context uses Pi's native retain-none compaction after the planning run
finishes. The next run receives the approved plan, its path and revision, and a
reference to the archived planning transcript. The session ID, transcript file
and plan path stay the same. Earlier messages remain on disk but are excluded
from the model's context. Implementation starts only after Pi confirms that the
approved context was committed and the plan still matches the reviewed revision.

Leaving Plan mode adds a one-time model-facing reminder with the plan path. An
undelivered reminder remains pending across restart. After later compaction, Pi
restores the current plan path and contents in both planning and ordinary modes.
The model uses the normal file tools to read or update the plan.

## Investigation and questions

Inspect known targets directly. Use Explore to locate code, tests and evidence
for a broad investigation. Use Plan to assess non-trivial implementation
approaches, trade-offs, reuse and verification. Both roles are available through
the normal `subagent` tool as `planning-explore` and `planning-plan`. The parent
supplies a focused task with requirements, constraints and prior findings for
each fresh context. Planning agents run in the background by default; set
`async:false` when the parent must wait for a result. Native completion
notifications let the parent continue independent investigation while children
run. Use the normal status, wait and cancellation controls.

Research children can delegate focused subtasks to either planning role through
`subagent`. Descendants inherit the research restrictions, required policy
extension and runtime depth and fan-out limits. The deployment permits two
levels of research agents and uses the native concurrency and fan-out limits.
Direct planning-role launches and read-only inspection or cancellation controls
are available; workflows and agent-authoring actions are blocked. Research
agents cannot edit project files or the parent's plan.

The general `ask_user` tool remains available to the parent, including outside
Plan mode. Children return unresolved questions to the parent. The parent writes
the final plan and requests approval through `submit_plan`. Pure research can
finish with findings without submitting an implementation plan. `submit_plan`
refuses to request approval while subagents are active; the model must wait or
cancel them. A human leaving Plan mode does not stop native background jobs.
Their inherited read-only restrictions remain in force until they finish.

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
inherited restrictions, background completion and the delegation depth limit.
