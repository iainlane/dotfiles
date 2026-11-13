# Planning

Plan an implementation before changing the project. Pi investigates the existing
code, develops an approach, resolves questions and writes a Markdown plan for
review. Focused Explore and Plan agents help the parent understand the code and
assess designs. The parent remains responsible for the final recommendation.

![An offline planning demo][demo-preview]

The recording uses a scripted provider with the extension's actual tools and UI.
It shows entry consent, a blocked project edit, plan review and scrolling,
Ctrl+G editing, review feedback, approval with a context reset, and
implementation in a temporary project.

[demo-preview]: demo/planning.webp

## Cooperative footer status

Planning keeps its native `planning` status (`plan mode on`) as a standalone
fallback. Alongside it, native `pi.events` publishes `dotfiles:status:v1`:

```typescript
type StatusPublication = {
  version: 1;
  source: "planning";
  sessionId: string;
  active: boolean;
  text?: string;
};
```

`active` is the actual Plan mode flag; no detail is supplied by default and no
implementation phase is inferred. A cooperating footer shows its configured
planning symbol alone. Optional producer-supplied detail belongs after that
symbol; consumers do not parse native display labels.

Consumers request a replay on `dotfiles:status:request:v1` with
`{ version: 1, sessionId: string }`. Planning replays its latest snapshot only
for the matching native session ID. Session restore republishes current state;
shutdown publishes inactive state and removes the replay listener. Consumers
validate versions/session IDs, sanitise detail text and retain inactive
snapshots to suppress stale native fallbacks. See
[the footer protocol](../pi-session-footer/README.md#cooperative-extension-status).
Neither extension needs the other installed.

## Starting and reviewing a plan

The entry guidance retains Claude Code's criteria and examples, with planning
reserved for significant unresolved design choices or an explicit request.
Bounded fixes and small features can proceed directly. Investigation, file count
and focused clarification alone do not require Plan mode.

- `/plan` enters or remains in Plan mode and displays the associated plan. If
  the file is missing, Pi reports its path. Displaying does not start a model
  turn.
- `/plan exit` leaves Plan mode without approving implementation.
- `/plan open` enters if needed and opens the saved plan in the configured
  external editor. This requires Pi's terminal UI and does not create a missing
  draft. Pi rereads saved changes even after an editor error.
- `/plan review` asks the model to finalise the active draft and request review.
- `/plan <task>` enters Plan mode and starts planning that task.
- Ctrl+Alt+P toggles Plan mode without starting a model turn.
- `pi --plan` starts a session in Plan mode.

When the model calls `enter_plan_mode`, Pi asks for consent before activating
Plan mode or creating a draft. No or Escape leaves the current mode unchanged.
An interrupted request cannot activate Plan mode later. Without a UI,
model-requested entry is refused. RPC clients must answer the confirmation
explicitly. The commands, shortcut and startup flag above are direct user
actions and do not ask again. Calls while Plan mode is already active do not ask
again either. Entry consent does not approve implementation; the completed plan
still requires separate review.

Entry associates a plan path without creating a placeholder. The file is created
on the first actual write. Drafts remain in Pi's agent directory under `plans/`
(`~/.pi/agent/plans/` by default) when Plan mode ends. This follows Pi's
`PI_CODING_AGENT_DIR` override. Returning to the same session preserves the
draft. A fork from a planning session gets its own copy. Reloading, resuming and
compaction preserve planning state. On re-entry, Pi asks the model once to read
the existing plan and compare it with the current request. A pending instruction
persists across restart, but later runs do not repeat an instruction already
delivered. A different task requires a new plan; a continuation requires an
update that removes obsolete details.

Ordinary `write` and `edit` calls below the agent plans directory display
`Updated plan` in both native Pi and the configured pi-pretty style. The heading
also applies outside Plan mode and to missing or failed targets. Path matching
uses native normalisation and directory boundaries; a sibling such as
`plans-other` does not match. The heading does not change tool identity,
execution or permissions.

The model presents the file for approval when the plan is ready. The complete
plan appears in Pi's transcript, with an approval question in the fixed editor
dock. In fullscreen mode, scroll with the wheel or Page Up/Down. In regular
mode, use the terminal's scrollback. The approval question combines Pi's native
selection and editing controls. Use Up/Down and Enter to choose:

- `Yes, keep context`: approve implementation in the current conversation.
- `Yes, clear context`: approve implementation and clear the conversation
  context.
- `No, keep planning`: submit revision feedback from the embedded multiline row.
- `Continue planning`: cancel review and continue planning.

Tab switches between the choices and the feedback editor. The other choices
remain visible while editing. Enter in the negative row requires text or an
attached image; Shift+Enter inserts a newline. Native cursor and mouse editing
remain available. Escape returns to the choices with the draft retained. An
explicit positive choice can include that feedback. Escape at the choices
cancels review and discards unsent text and images. Typing or attaching feedback
does not approve implementation. Pi displays its native context usage when
available; unknown usage is not estimated by this extension. Approval displays
`User approved Pi's plan` separately from the plan body. The plan item contains
the plan and its path, without an approval instruction or revision hash.

Use the configured `app.clipboard.pasteImage` binding (Ctrl+V by default) to
attach a native clipboard image. PNG, JPEG, GIF and WebP are supported;
unsupported formats, including BMP, are refused explicitly. Native clipboard
support varies by platform. Linux support depends on X11; this extension adds no
Wayland or clipboard-command fallback. Unavailable, empty and failed image
transfers leave text feedback available. Pending transfers cannot approve a
plan, and late results are discarded after cancellation. Images remain native
image blocks in tool results and implementation context, not base64 Markdown.
Pi's public image processor validates encoded images and applies its native size
and dimension limits. The current `blockImages` and `autoResize` settings apply.
If auto-resizing is disabled, an image above those limits is refused. Models
without declared image support cannot accept image feedback. Provider context,
image-count and request limits still apply.

Ctrl+G opens the actual plan file in your editor. This uses Pi's configurable
`app.editor.external` keybinding and the effective `externalEditor` setting,
then `VISUAL`, `EDITOR`, or Pi's platform default. Quoted executable paths and
literal arguments are supported; use a wrapper script for shell constructs. GUI
editors need a wait-capable command such as `code --wait`. After the editor
returns, Pi rereads and displays the saved revision. Editing does not approve
the plan; approve the updated version explicitly. Approval returns the complete
reviewed plan to the model, including edits made before review began. Edits made
during review also reach the model when requesting revisions or cancelling,
without granting implementation approval. Saving identical contents does not
publish another preview. Clear-context approval includes the complete reviewed
plan and any review feedback in the new context.

Both planning tools are sequential, model-only interactions. `enter_plan_mode`
is available in ordinary work. `submit_plan` is active only while Plan mode is
active; leaving Plan mode or starting approved implementation removes it from
the model's tools. Reload, resume, compaction and tree navigation restore review
availability from the planning state without changing other tool selections.
Call the planning tools outside codemode with an empty argument object. Entry
returns an explicit active or declined result; submission returns a versioned
structured result with the presented plan and decision. The final tool result
retains the displayed snapshot for transcript reconstruction.

RPC clients receive the context choices through Pi's dialogue protocol, with
`Add a comment` and a separate input request for feedback. Blank revision
feedback cancels review; RPC does not expose the embedded TUI or image input.
Approval applies to the displayed revision. If the file changes during review,
Pi asks for another review. Cancelling a dialogue or answering a question does
not approve implementation. Toggling Plan mode off preserves the draft and ends
the tool restrictions; it does not record plan approval.

## Review safety and history

Inline plans and text feedback are each limited to 200,000 UTF-16 code units.
Oversized editor returns cannot be approved, and oversized feedback remains
editable. Invalid UTF-8 documents and invalid Unicode feedback are refused.
Terminal controls and bidirectional formatting controls appear as visible
Unicode escapes. Displayed paths use home-relative notation where possible and
escape embedded layout controls. Presentation does not change the canonical plan
content or its revision.

Approval, revision requests, cancellations, feedback and implementation failures
have separate, versioned native history entries. Outcome entries do not add
model instructions or restore implementation authority. Supported older plan
snapshots remain readable; unrecognised results are labelled as legacy/raw
content with expandable metadata. The plan body does not contain an approval
caption.

Research must be idle both before review and after an approval choice. New user
input or a planning command cancels pending review authority, including during
that second idle check. Settlement verifies research and the document again.
Failed verification and failed implementation launches do not reuse the ticket.

Offline tests capture complete request bodies from the native Anthropic
Messages, OpenAI Responses, OpenAI Completions and Google Generative AI HTTP
clients. They cover boundary-size plans and feedback, JSON escaping, UTF-8 and
native image blocks. Native RPC tests also exercise boundary-size previews,
feedback and structured results. These checks verify client serialisation, not
remote model acceptance or every provider and platform.

## Implementation context

Both approval choices finish the planning run before starting a fresh native
implementation run in the same session. Keep-context approval preserves the
conversation. The implementation run receives refreshed system instructions, the
exact approved plan and review feedback.

Clearing context uses Pi's native retain-none compaction after the planning run
finishes. The next run receives the approved plan, its path and revision, and a
reference to the archived planning transcript. The session ID, transcript file
and plan path stay the same. Earlier messages remain on disk but are excluded
from the model's context. Implementation starts only after Pi confirms that the
approved context was committed and the plan still matches the reviewed revision.

A manual exit adds a one-time model-facing reminder, including the plan path
when the file exists. A missing draft does not suppress the exit notice. An
undelivered reminder remains pending across restart. After later compaction, Pi
restores the current plan path and contents in both planning and ordinary modes.
The model uses the normal file tools to read or update the plan. An approved
implementation transition does not send the manual-exit reminder.

## Investigation and questions

Inspect known targets directly. Use Explore to locate code, tests and evidence
for a broad investigation. Use Plan to assess non-trivial implementation
approaches, trade-offs, reuse and verification. Both roles are available through
the normal `subagent` tool as `planning-explore` and `planning-plan`. The parent
supplies a focused task with requirements, constraints and prior findings for
each fresh context. Planning agents run in the background by default; set
`async:false` when the parent must wait for a result. Native completion
notifications let the parent continue independent investigation while children
run. Use the normal status, wait and cancellation controls. Planning does not
set a default research-job timeout. Callers can choose `options.timeoutMs` on
native `subagent` calls; omitted values follow native pi-subagents policy.

Research children can delegate focused subtasks to either planning role through
`subagent`. Descendants inherit the research restrictions, required policy
extension and runtime depth and fan-out limits. The deployment permits two
levels of research agents and uses the native concurrency and fan-out limits.
Direct planning-role launches and read-only inspection or cancellation controls
are available; workflows and agent-authoring actions are blocked. Research
agents must not edit project files or the parent's plan. Their ordinary
file-editing tools are blocked; shell and MCP execution follows native policy.

The general `ask_user` tool remains available to the parent, including outside
Plan mode. Children return unresolved questions to the parent. The parent writes
the final plan and requests approval through `submit_plan`. Pure research can
finish with findings without submitting an implementation plan. `submit_plan`
refuses to request approval while subagents are active; the model must wait or
cancel them. A human leaving Plan mode does not stop native background jobs.
Their inherited planning guards and native permissions remain in force until
they finish.

Planning guidance is refreshed when a new run starts. Concise reminders are
added after five completed turns and after compaction.

## Tool restrictions

The parent and research descendants can read and search, use Lens, consult the
web and use normal native MCP discovery. Web and Lens activation tools are
permitted. LSP navigation and AST rewrites are available as read-only operations
or edit previews; applying changes remains blocked. The parent can use ordinary
`write` and `edit` calls for the active plan only. Nested codemode calls receive
the same checks.

`planning.json` specifies the `researchExtensions` to load in children. Child
runtimes initialise Pi's native MCP and tool-search extensions without a
planning-specific server/tool list. Normal MCP configuration, exposure, project
trust and permissions apply. MCP resource tools become available after a
resource-capable server connects; they are permitted by planning policy but are
not required at child startup. Other research tools available in the parent are
required in the child. This does not copy parent-only tools or load their
extensions. Parent-only extension registrations follow native inheritance rules;
planning does not copy server registrations or credentials.

Planning does not classify, confirm, deny or rewrite shell commands. Parent,
child and nested codemode calls use native bash and the host's ordinary
permission hooks. MCP calls use the same normal dispatch. Independent native
capability ceilings still apply.

The research instructions prohibit implementation, but planning is not an
operating-system sandbox. If native policy permits a shell or MCP action,
planning adds no command or MCP restriction. This configuration does not install
an automatic permission classifier. Command permission does not approve a plan.

## Recording the demo

The [VHS tape][demo-tape] uses Pi 1.4, Node.js 24 or later, Vim, VHS 0.12.1 and
FFmpeg. VHS also needs its ttyd and browser dependencies. Use cell-based
terminal sizing when changing the tape dimensions so the PTY and recording agree
on the number of rows. Follow the [local validation setup][validation] first,
then record from this directory:

```sh
PI_TEST_HOST="$native/bin/pi" \
PI_TEST_SUBAGENTS="$subagents/lib/node_modules/pi-subagents" bash demo/record.bash
```

[validation]: #validation

The launcher creates a temporary home, agent directory and project, and runs Pi
with an explicit environment, offline mode and no discovered extensions or MCP
servers. It loads the planning extension, subagent runtime and [demo provider].
The provider scripts model responses without external model requests; the
extension enforces its normal policy and revision checks. The launcher deletes
the temporary workspace when Pi exits.

The tape edits the plan through Vim, adds a review comment and approves clearing
context. The provider refuses to continue unless the project edit was blocked,
the edited plan and feedback are included in the next run, the earlier research
has been removed, and the session ID is unchanged. The final check runs the
fixture CLI and verifies that its temporary cache file still exists.

The recording script produces the animated `demo/planning.webp`, then removes
its intermediate recording. `PI_TEST_HOST` selects the compiled Pi executable;
otherwise the launcher uses `pi` from PATH. The launcher loads the npm subagent
dependency by default. `PI_TEST_SUBAGENTS` selects a deployed `pi-subagents`
package root.

[demo-tape]: demo/demo.tape
[demo provider]: demo/provider.ts

## Validation

The profile and package checks use the patched compiled Pi executable. Its SDK
adds the public heading resolver, render context, component accessor, path
helper and asynchronous message-error callback. The package build installs that
SDK in place of npm's `@earendil-works/pi-coding-agent`, and installs this
repository's `pi-subagents` build in place of npm's release. The release's
prebuilt Node CLI bundle is unchanged; use the compiled executable for CLI
checks. Setting `PI_TEST_HOST` alone does not change Node imports or TypeScript
resolution. Restart Pi after deploying the profile. Reloading extensions does
not replace a compiled host that is already running.

Allow this directory's `.envrc` with direnv, then install and check:

```sh
pnpm install
pnpm check
```

The development shell sets `PI_TEST_HOST`, `PI_TEST_PRETTY`, `PI_TEST_DIFF` and
`PI_TEST_SUBAGENTS` to the matching builds. It links this repository's builds of
the SDK and `pi-subagents` into `.nix-providers`, and pnpm installs them from
there in place of the npm releases. After changing dependencies, run
`nix run .#update-pi-planning` from the repository root. It refreshes the
overrides, the lockfile and the Nix dependency hashes. Deployed extensions do
not include host SDK modules; startup checks reject bundled copies.

The subagent package includes the child-runtime registration patch required for
nested planning roles. Native tests exercise web and Lens activation, unfiltered
MCP discovery, native permission denials, inherited planning guards, background
completion and the delegation depth limit. A gated local MCP server reproduces
child startup before resource registration, without sleeps or external requests.
The scripted child then uses native tool search and all three resource tools.
Heading tests cover both planning/pretty load orders and all six orders with
pi-diff, grouped rows, streamed arguments, replay and native Edit's preview and
result rebuild. An offline native regression also covers automatic threshold
compaction after keep-context approval, with stale plan wording and a
contradictory summary. The regression verifies inactive planning state, a
nonplanning system prompt, continued project writes and no replayed approval. It
does not test a model's interpretation of the restored text.
