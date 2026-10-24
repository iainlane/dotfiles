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

The parent normally asks one Explore agent to investigate relevant code and one
Plan agent to assess the approach. Up to three distinct investigations can run
concurrently. Small tasks can skip delegation. Children begin with fresh
contexts, so the parent supplies requirements, constraints and prior findings.

The general `ask_user` tool remains available to the parent, including outside
Plan mode. Research agents return unresolved questions to the parent. They
cannot ask the user, delegate further or approve implementation.

## Tool restrictions

The parent can read and search, use Lens, consult the web and call configured
read-only MCP tools. Ordinary `write` and `edit` calls may change only the
active plan. Nested codemode calls receive the same checks.

Recognised shell inspections run with potentially executable Git helpers
disabled. Known mutations are blocked. An unclassified parent command requires
explicit permission for that command; research children must return the
investigation to the parent. Command permission does not approve the plan.

These are tool and command policies, not an operating-system sandbox. The
policies trust the configured shell, executable resolution, inherited
environment and extension implementations. Changing shell prefixes or replacing
tools changes that boundary.
