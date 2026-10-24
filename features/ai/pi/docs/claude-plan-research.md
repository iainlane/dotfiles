# Claude Code planning research

This report describes Claude Code 2.1.302, inspected on 24 October 2026. It
establishes the planning architecture and the relevant execution paths. It does
not propose a Pi implementation.

Claude combines a parent planning prompt, specialised research agents, ordinary
permission machinery, persistent plan files and a dedicated approval interface.
The five planning phases are instructions to the model. The runtime enforces
tool availability, permission transitions and interaction lifecycles, but does
not enforce a five-phase state machine.

Most questions about this architecture can be answered through source
inspection. Effective configuration and external inputs determine some branches.
Actual model choices and planning quality need separate observation or
evaluation.

## 1. Version, method and confidence

### Executable identity

The installed command passes through Nix wrappers to this executable:

```text
/nix/store/p1y1c5zdrcmr64fk6c2jsb8af5v9g34x-claude-code-2.1.302/bin/.claude-wrapped
```

| Property                 | Inspected value                                                    |
| ------------------------ | ------------------------------------------------------------------ |
| Version                  | `2.1.302`                                                          |
| File size                | `267956720` bytes                                                  |
| SHA-256                  | `5262ce9de86243fed0d21edc39b271555d56780d0112e2b194439fe1c6662d37` |
| Embedded Git revision    | `2ef144e6f98c1c99d082b735e4b38f50e3391e55`                         |
| Embedded build timestamp | `2026-10-16T15:52:41Z`                                             |

The outer installed wrapper resolves through
`/nix/store/3nx1bdfsn2crdzm8jn8rhdzdid190k1s-claude/bin/claude` and
`/nix/store/5d61igq61mvf1nwkgxzribcmsjjg0d92-claude-code-2.1.302/bin/claude`.
The intermediate `.claude-wrapped_` file is another shell wrapper. The final
executable above contains the embedded application source.

The wrappers can configure TeamClaude. They disable the updater and installation
checks, and default `DISABLE_NON_ESSENTIAL_MODEL_CALLS` to `1`. These wrapper
settings do not establish which planning branch an existing process selected.

### Evidence categories

The investigation used readable embedded source in the native executable,
official documentation and isolated execution of extracted decision functions.
There were no model calls, application activation, installations or repository
code changes during the investigation.

The findings use four distinct forms of evidence:

- Prompt instructions establish what the model is told to do. They do not prove
  that the model follows the instructions.
- Runtime paths establish deterministic behaviour for stated inputs.
- Isolated probes verify extracted functions with explicit dependency stubs.
  They do not exercise the complete terminal application or a provider.
- Configuration snapshots establish selected local values at inspection time.
  They do not establish the inputs of a different or already-running process.

The official [Plan-mode documentation][plan-mode], [subagent documentation]
[subagents] and [permission documentation][permissions] provide public context.
Those pages can describe a newer version. For example, the subagent
documentation includes resume behaviour introduced after 2.1.302. The exact
binary is the authority for version-specific findings in this report.

[plan-mode]:
  https://code.claude.com/docs/en/permission-modes#analyze-before-you-edit-with-plan-mode
[subagents]: https://code.claude.com/docs/en/sub-agents
[permissions]:
  https://code.claude.com/docs/en/permissions#hook-approvals-in-plan-mode

### Durable source references

Every byte offset in this report is zero-based in the executable identified
above. Ranges are end-exclusive. Minified identifiers are search aids, not
stable APIs. Appendix A contains the complete range index. The executable
digest, offsets and identifiers make the findings reproducible without the
temporary extraction files.

For example, this command prints the parent planning source without executing
Claude Code:

```sh
python3 - /nix/store/p1y1c5zdrcmr64fk6c2jsb8af5v9g34x-claude-code-2.1.302/bin/.claude-wrapped <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_bytes()
print(source[225726750:225740600].decode("utf-8", errors="replace"))
PY
```

Temporary research artefacts were created under `/tmp/claude-plan-research/`:
`evidence-index.json`, extracted source ranges, `static-probes.ts`,
`probe-source-index.json` and `static-probe-results.json`. The report does not
depend on those files remaining available.

## 2. The parent planning workflow

The normal parent prompt builder is `a6n` at byte `225730374`. Its surrounding
renderers, including `Bbs`, `Hbs`, `s6n`, `d6n` and `i6n`, select and repeat the
appropriate instructions.

### The five phases

| Phase            | Instructions to the parent                                                                                                                                                       |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Understand       | Understand the request and relevant code. Look for reusable functions and patterns. Use Explore agents for focused code discovery.                                               |
| Design           | Use Plan agents to design an implementation from the requirements and exploration findings. For most tasks, launch at least one. Truly trivial changes can skip this delegation. |
| Review           | Read critical files personally, check the proposed design against the request and resolve remaining questions with the user.                                                     |
| Finalise         | Write the recommended plan to the designated plan file. Include context, the recommended approach, critical files, reusable code and verification.                               |
| Request approval | Call `ExitPlanMode` when the plan is ready for review.                                                                                                                           |

The understanding phase normally recommends one Explore agent and permits
parallel agents for independent questions. The design phase asks the parent to
give each Plan agent the user intent, relevant findings, paths and execution
traces, constraints and, when useful, a distinct design perspective. For
repetitive changes, the final plan can specify representative paths and the
pattern without enumerating every instance.

These are model instructions. The source does not require an Explore result
before a Plan call, or a Plan result before `ExitPlanMode`. The reminder tells
the model to finish a planning turn through `AskUserQuestion` or `ExitPlanMode`.
The inspected paths do not implement a general validator for that final
instruction.

### Delegation counts and concurrency

`KYn` at `225645157` computes the recommended Plan-agent count. The default is
one. Team, Enterprise and the `default_claude_max_20x` tier can use three.
`CLAUDE_CODE_PLAN_V2_AGENT_COUNT` overrides the value when it is numeric,
greater than zero and no greater than ten.

`VYn` at `225645367` computes the Explore count. The default is three, with the
same bounds for `CLAUDE_CODE_PLAN_V2_EXPLORE_AGENT_COUNT`.

Both values are inserted into instructions. They are not dedicated runtime
limits. The generic subagent concurrency default is twenty, computed by `f_r`
near `223286250`, with `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` as an override.
The runtime checks concurrency near `229158950`, subject to separate host and
feature branches. Built-in research roles cannot launch nested agents because
their tool sets exclude `Agent`.

## 3. Which parent prompt is selected

The specialised Explore/Plan workflow requires both `eW()` and
`g1() === "default"`.

`eW`, near `220971872`, latches whether
`CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS` is unset. The steering functions `bO`,
`g1` and `Ss` around `214963600` resolve the following inputs in order:

1. `CLAUDE_CODE_THISTLE_GREBE`.
2. Host client data for `tengu_thistle_grebe`.
3. The feature-service value for that key.
4. A registered model-dependent fallback.
5. The default value.

The recognised variants are `default`, `no_nudges` and `counter_steer`. `mfn`
near `223450269` registers a possible `no_nudges` fallback before prompt
sections are assembled. An explicit feature value of `default` takes precedence
over that fallback. The selected steering value is latched; reminders do not
independently select a new branch each time.

Other rendering branches matter:

- Custom `planModeInstructions` replace the normal workflow body. The
  restriction preamble and exit instructions remain.
- A child agent receives the child planning reminder through `jbs`, not the
  parent's five-phase instructions.
- A host without a plan-file interface receives the `Wbs` branch. The model
  returns the plan in its response, and the user controls leaving Plan mode.
- Full and shorter reminders use different renderers.
- Workshop, prototype, Ultraplan and team workflows have separate conditions.
  Their presence does not make them the ordinary interactive planning path.

### Local configuration snapshot

The inspected global settings selected `claude-mythos-5-1`. The examined
settings did not explicitly configure `effortLevel`, `alwaysThinkingEnabled`,
`showClearContextOnPlanAccept`, `askUserQuestionTimeout`, `dialogExpiry`,
`useAutoModeDuringPlan`, `agent` or `plansDirectory`. The examined global and
project permission settings did not set `defaultMode`, `disableBypass` or
`disableAuto`.

Selected cached feature values were `tengu_thistle_grebe = "default"`,
`tengu_snappy_pelican = false` and `tengu_cinder_plover = ""`. The inspected
process environment and settings environment contained none of the selected
planning or subagent overrides. Credential values were not inspected or
included.

This snapshot supports the ordinary branch for those inputs. A particular
running process can have different launch arguments, host client data or
previously latched feature values. Its effective input snapshot would resolve
that question without a model call.

## 4. Explore and Plan agents

### Roles and prompts

The built-in definitions are `XR` for Explore and `Hae` for Plan, within
`221026700:221033900`. Both specify `model: "inherit"` and `omitClaudeMd: true`.

Explore's prompt builder, `vto`, describes a file-search specialist. The prompt
requires read-only work, including no temporary-file creation, and asks for an
efficient report of findings. The caller can specify quick, medium or very
thorough exploration.

Explore's selection descriptions, `Tto` and `Eto`, are narrower than a generic
research role. They distinguish code discovery from code review, design audits,
consistency reviews and open-ended analysis. The lean description warns that
Explore reads excerpts. A successful code search is not evidence of a complete
review.

Plan's prompt builder, `Cto`, describes a software architect. The prompt asks
the agent to understand the supplied requirements and perspective, read the
provided files, investigate architecture and patterns, consider trade-offs and
produce ordered implementation steps with dependencies and challenges. The
response ends with three to five critical implementation files. The Plan agent
returns its design to the parent; the parent writes the final plan file.

### Effective tools

Both role definitions explicitly exclude `Agent`, the Artifact tool family,
`ExitPlanMode`, `Edit`, `Write` and `NotebookEdit`. The general subagent tool
filter also removes interactive tools such as `AskUserQuestion` and
`EnterPlanMode`. Separate planning additions do not override the roles' explicit
exclusion of `ExitPlanMode`.

The result is not a fixed four-tool allowlist. The resolver `Jd` at `229036281`
combines the available tool catalogue, role exclusions, aliases, dynamic MCP
tools, permission rules and asynchronous execution restrictions. Shell access,
skills and applicable MCP tools can remain available. The effective catalogue
must be computed from the host's actual inputs.

The research roles cannot ask the user questions themselves. The parent collects
their findings and uses its question tool when clarification is needed.

### Initial context and instruction inheritance

The delegation path `Go`, around `229137500:229142000`, resolves the agent
definition, creates the child's system prompt, prepares the delegation message
and starts the child loop. It passes the parent's transcript as
`forkContextMessages` only on the explicit fork branch. Ordinary Explore and
Plan calls start with fresh transcript context.

Fresh context has several qualifications:

- The child receives the parent's delegation prompt and independently built
  system and environment context.
- Optional human-intent forwarding can include selected user messages as
  background. `n2s` and related helpers implement this path; the environment
  override is `CLAUDE_CODE_FORWARD_USER_INTENT`.
- `omitClaudeMd` removes the initial `claudeMd` component for the relevant
  built-in and policy-settings paths through `Md` near `229023122`. Managed
  instruction variants have separate treatment.
- Later file reads can load scoped instructions. Omitting initial CLAUDE.md
  content does not disable instruction discovery throughout the run.
- Hooks, skills, host attachments, MCP descriptions and a gated appended
  subagent prompt can add context. The append override requires
  `CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT`.

The child runtime `PA` creates fresh read-file state on the non-fork path. The
environment builders `LA` and `ULo` can add working-directory, platform, date,
user and project context. Explore and Plan omit the normal Git-status context.
The child postamble `n7t` adds applicable execution instructions, such as
absolute paths and returning findings directly, depending on the model and host.
The child does not automatically inherit the parent's entire coding system
prompt and output style.

Explore's complete transcript is not automatically forwarded to Plan. The parent
selects and summarises useful findings in the Plan delegation.

The child normally executes in the parent's working directory. An explicit
directory or worktree-isolation option changes that environment through the
generic subagent runtime. Fresh model context does not imply a separate
filesystem or working tree.

### Models, effort and thinking

Both roles request inheritance. Explore's `ube` resolver can cap inheritance at
the Opus family for applicable provider/model combinations. The cap is disabled
by `CLAUDE_CODE_DISABLE_EXPLORE_INHERIT_CAP`; other provider branches inherit
normally. The inspected version does not universally force Explore to Haiku.

The generic model resolvers, including `JB`, `vms` and `ozt`, combine the role,
tool call, environment, forced overrides and model availability. An explicit
role value of `inherit` can take precedence over a generic default subagent
model setting. A forced override has separate precedence.

`lxn` at `229079955` resolves effort from session, model, inherited and explicit
agent inputs. The `tengu_harmonic_riddle` feature can reduce inferred effort
under its conditions; an explicit effort setting follows a different path.
Neither built-in research role specifies a fixed effort level.

`mWs` at `215267799` suppresses a thinking-display option for a particular
headless foreground path. The function preserves the remaining thinking
configuration. Display suppression is not evidence that reasoning is disabled.

### Result identity

Explore and Plan are included in a one-shot role set near `216947069`. Their
normal completed result omits the agent identifier and continuation footer, and
automatic display naming has a corresponding exception. Internal task and
transcript objects still have identifiers. The source supports a one-shot public
interaction pattern, not a claim that internal continuation is physically
impossible.

## 5. Foreground, background and cancellation

### Execution selection

The generic selection function `yo` at `229113099:229113414` establishes these
results for the probed inputs:

| Inputs                                                   | Result                                               |
| -------------------------------------------------------- | ---------------------------------------------------- |
| Ordinary top-level delegation, background choice omitted | Background by default                                |
| Explicit background choice of `false`                    | Foreground, unless another forcing condition applies |
| Background tasks disabled                                | Foreground, except the remote-isolation branch       |
| In-process teammate or headless-subagent caller          | Foreground by default                                |
| Agent definition requires background execution           | Background                                           |
| Remote isolation                                         | Asynchronous                                         |

The full function also considers coordinator status, forced asynchronous
execution and the web-fetch exception. Planning has no dedicated override that
forces every Explore or Plan call into the foreground.

This establishes generic API semantics. It does not prove which arguments the
model normally chooses during the planning phases. The parent instructions
require the parent to obtain and use findings, but the inspected planning prompt
is not an execution scheduler. An actual delegation transcript would establish
the invocation choices for a particular run.

### Abort ownership and background transition

Foreground registration through `Ghs` near `225528001` uses a controller linked
to the parent's abort signal through `U0e`. The relay preserves the abort reason
and handles an already-aborted parent immediately.

Background registration through `Pse` at `225526396` receives no parent abort
controller on the ordinary `Go` path. It creates an independent controller.
Background execution also uses a non-interactive permission context through
`Wdr`.

A foreground call waits for completion or a background transition. `t4e` updates
the task's background state. The waiting path detaches the parent abort relay
when backgrounding succeeds, then returns the asynchronous task metadata. Later
completion is reported separately.

Cancelling the parent turn therefore cancels a linked foreground child. The same
action does not automatically cancel a child which has already become an
independent background task. Explicit stop operations are separate.

### Termination, errors and partial results

`RC` at `225521131` marks a task as killed, records the cause, aborts its
controller and performs associated cleanup. Task notification paths guard
against duplicate terminal reporting. Descendant shell cleanup and explicit
stop-all behaviour have their own paths.

The agent run loop `DQ`, within `229058200:229069800`, distinguishes completed,
failed, killed, parked and watchdog outcomes. The watchdog defers termination
while a tool is in flight. The `PA` finalisation path cleans up applicable
hooks, MCP connections, monitors, shell state and telemetry after interruption.

`mu` and `Sss`, within `229054900:229058500`, can recover usable partial text
from rate-limit, overloaded and server-error cases. Other errors propagate or
use their own narrower recovery conditions. A turn-limit outcome can also report
partial work. Terminal notifications retain outcome information; usable partial
text is not equivalent to a completed design.

## 6. Questions and interaction lifecycle

### Tool and schema

`AskUserQuestion` is a general interactive tool, not a Plan-mode-only facility.
The definition `yQ` is within `229279400:229295200` and declares that user
interaction is required.

The ordinary schema accepts one to four questions. Each question has text, a
short header, two to four options and a multi-selection flag. Options include
labels and descriptions, with optional preview content in supported variants.
The UI supplies free-form alternatives. Schema refinements reject duplicate
question text and duplicate option labels. Host-specific extended forms add text
and number questions, titles and related presentation fields.

Answers are collected through the permission/UI path before the tool's normal
call processes them. Asking a question does not approve a plan. Plan approval
uses `ExitPlanMode` and its separate dialogue.

### Request identity, cancellation and stale answers

The terminal question dialogue is `permission_ask_user_question`, created
through `P_e`. The plan approval dialogue is `permission_exit_plan_mode_v2`,
created through `VVt`. Both typed adapters default to a cancelled result.

The request transport `FOe` at `243269914:243270984` keeps pending resolvers by
request identifier. Its deterministic behaviour is:

1. Without a renderer, or with an already-aborted signal, cancel asynchronously
   without emitting a new UI request.
2. On abort, remove the pending resolver, resolve cancellation and emit the
   cancellation event.
3. On a reply, remove the resolver before resolving the result and detach the
   abort listener.
4. Ignore replies and updates for identifiers which are no longer pending.

The permission coordinator also uses the claim-once/resolve-once guard `Jsr` at
`242405639`. Local UI, hooks and remote permission responses compete through
this shared guard. The typed adapter validates payloads and results; malformed
results and transport errors use the declared default.

The renderer binding `KN`, around `244456200`, opens requests in the UI store,
retracts requests on cancellation and cancels outstanding requests when the
renderer unmounts. The store `Hqr` removes an answered or dismissed request
before emitting its closure. A delayed response cannot approve a newer request
merely because the dialogues look alike.

### UI outcomes and turn cancellation

The question UI `Nve` handles selection, free-form responses, submission and
cancellation. Some single-question selections can submit immediately. A local
guard prevents double submission. Human interaction takes precedence over an
in-flight automatic AFK answer. The clarify/respond path returns denial with
feedback so the parent can reformulate.

`JVt.cancelAndAbort`, near `242406500`, distinguishes denial with feedback,
denial without feedback and cancellation. For a parent request, feedback can
return control without aborting the turn; cancellation or an unqualified denial
can abort the turn. Subagent and host-specific withdrawn-request paths differ.
The permission coordinator does not turn cancellation into a successful empty
answer.

### Timeouts

The default `askUserQuestionTimeout` is `never`. The optional AFK path supports
sixty seconds, five minutes or ten minutes. It uses activity and focus state,
shows a countdown and checks activity again before submitting an asynchronous
answer. Under its configured conditions, the question path can submit partial
answers. This mechanism does not automatically approve plans.

Remote dialogue expiry is a separate host/transport concern. Source establishes
the request identifier and cancellation contract. Whether a particular remote
answer was delivered needs transport evidence for that request.

## 7. Mode entry, plan files and approval

### Entering Plan mode

`EnterPlanMode`, defined as `$kn` around `229266000`, has an empty public input
schema. Its validation rejects child-agent use. The call updates the session's
permission mode to `plan` and preserves relevant previous-mode information
through `NTt`.

The tool's descriptive prose says entry requires user approval. The definition
does not supply its own `checkPermissions` method, and the generic tool factory
`Qt` defaults that method to allow. A dedicated entry dialogue exists, but the
normal permission machinery must first require a prompt before that dialogue is
used. The code therefore does not establish that every tool-driven entry opens a
consent dialogue. The user can also change mode through the interface.

### Permission enforcement

The parent prompt permits writing only the designated plan file. Research-agent
prompts prohibit all mutations, including temporary files. Those statements are
instructions, not an operating-system sandbox.

The runtime has additional layers. Ordinary edit permissions include a Plan-mode
guard through `ly` around `217601200`. `Ml` at `217565157` recognises applicable
plan paths. Internal write exemptions through `nve` at `217606549` precede the
general Plan-mode floor and include conditional scratch, job and memory paths as
well as plans. Shell policy uses command classification and permission settings.
Available MCP tools and hooks have their own contracts.

The public permission documentation describes further rules, including the
restriction on hook approval of non-read-only actions in Plan mode. These layers
must be considered separately. Read-only planning is not a filesystem sandbox,
and removing `Edit` and `Write` does not prove that every remaining tool is
incapable of mutation.

### Plan storage and recovery

The storage implementation is within `217161000:217178500`. By default, plans
are Markdown files under the Claude configuration directory's `plans` directory,
using a generated session slug. Applicable child/team plans have agent-specific
suffixes. A custom `plansDirectory` is validated against the project path with
path and realpath checks. Storage-v5 and host variants are separate branches.

The implementation reserves slugs against collisions and invalidates read caches
when necessary. `VDt`, near `217172645`, restores an existing plan slug. When
the plan file is absent, recovery can use snapshots and recorded plan history.
`le` can recover content from `ExitPlanMode` input, user plan content or a
plan-file reference. Recovery is bounded and does not treat an arbitrary read
error as proof that a file is absent.

Fork handling through `OTo` can copy an existing plan and workshop state to a
new slug. On re-entry, the parent prompt tells the model to read the existing
plan, decide whether the request continues the same task, and revise or replace
the plan as appropriate before requesting approval. That task assessment is a
model decision.

### Presenting and editing a plan

`ExitPlanMode`, defined as `j3` within `228884000:228893800`, validates that the
ordinary caller is in Plan mode. Its public `allowedPrompts` field is marked
deprecated and unused. Internal input adds `plan` and `planFilePath` from disk.
The tool ordinarily requires user interaction and returns an explicit permission
request.

Normalisation through `Cxt` and the plan reader `aqe` binds the approval input
to plan content and path. The reader invalidates cached plan reads. The dialogue
descriptor `Eo` obtains the applicable plan information for review. The approval
UI can open an external editor through Ctrl+G and records locally edited plan
text. The pure result adapter `Cit` includes the edited text in the approved
tool input.

The resulting contract is more precise than approving a mutable path: review has
request identity and plan content, and an edit changes the input used by the
approved call. This observation does not establish a general filesystem lock or
an arbitrary concurrent-file-edit detection scheme.

### Approval outcomes

The menu builder `kit`, result mapper `Cit` and UI `xit` are within
`244348248:244360000`. Available choices depend on settings and capabilities.

| Outcome                     | Runtime behaviour                                                                                                                               |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Accept with current context | Allow the tool, apply the selected permission-mode updates and continue the existing conversation. Include edited plan content when applicable. |
| Request changes             | Return denial with feedback or attached images. Plan mode remains active for revision.                                                          |
| Empty changes submission    | Keep the form open when there is no feedback or image.                                                                                          |
| Cancel                      | Deny or cancel the old interaction and stop its turn; do not approve implementation.                                                            |
| Accept with clear context   | Deny the old tool request and queue a distinct implementation continuation with the plan and chosen target mode.                                |

The selected permission mode can be manual/default, accept edits, bypass or
auto, subject to availability and policy. The UI can update the mode before `j3`
finishes. The tool restores `prePlanMode` only if the current mode is still
`plan`. If a previous auto mode is unavailable, the tool can fall back to the
default mode and report that fallback.

Untrusted or oversized plan rendering can withhold the ordinary approval
controls. An empty plan has a separate exit-confirmation path. Those branches
should not be confused with approval of a complete implementation plan.

### Clear-context implementation handoff

`showClearContextOnPlanAccept` defaults to false in this version. When the
clear-context choice is available and selected, the UI queues an
`initialMessage` containing the plan, feedback and old transcript path. The
message includes `clearContext: true`, the `plan_mode_exit` reset trigger and
the target permission mode. The old approval request returns denial because the
continuation proceeds through a different path.

The consumer around `244551300` calls `Leo`/`clearConversation` within
`235846600:235852700`. That function generates a new conversation UUID, emits
`conversation_reset`, clears conversation state and runs the applicable clear
hooks. It also resets transcript, read/tool and session state and handles
selected tasks.

The consumer captures the old plan slug before clearing, associates that slug
with the new session afterwards through `zxr`, selects the target permission
mode and starts the implementation message.

This is a new conversation identity inside the existing application process. It
is not merely a compacted transcript or the same conversation with earlier
messages hidden. Normal approval retains the conversation identity and context.

### Team variant

A teammate's `ExitPlanMode` can send a request with a unique request identifier
to the team lead and report `awaitingLeaderApproval`. That result does not mean
that Plan mode has ended. The ordinary Explore and Plan roles cannot use this
path because they exclude `ExitPlanMode`. Team approval is a separate workflow
from the normal parent/user approval dialogue.

## 8. Resume and re-entry

The resume-mode module is within `247562000:247567000`. Its transcript scan,
`ssr`, classifies the relevant plan segment as open, exited or absent.

The scan recognises Plan-mode attachments and re-entry, successful
`EnterPlanMode` and `ExitPlanMode` tool results matched to their tool-use
identifiers, recorded user permission modes and explicit exit attachments.
Rejected exits do not close the segment. A teammate's pending lead-approval
result does not close the segment either. Duplicate identifiers are guarded. A
later human record in a non-plan permission mode prevents stale inference from
an earlier open segment.

`pni`, at `247565978:247566556`, restores interactive Plan mode only when its
eligibility conditions permit restoration. A pinned startup mode takes
precedence, a fork does not automatically restore the original mode, and the
exit tool must be enabled and permitted. The `tengu_tranquil_fern` gate defaults
to true.

When the stored permission mode is `plan`, restoration is suppressed if the
transcript establishes a successful exit. When the stored mode is absent or
invalid, an open transcript segment can restore Plan mode. A valid explicit
non-plan stored mode is treated differently from an absent value.

The interactive wrapper `Rvt` around `229879907` adds applicable startup
proactivity conditions before invoking the module. The startup path and slash
resume path call the restoration logic under different conditions; slash resume
also checks the operation and whether that session was already visited.

Print/SDK restoration has explicit trusted-record and transcript branches in the
same module, invoked within `249093300:249103000`. Explicit mode selection,
forking, SDK URL and tool eligibility affect those branches. Interactive
restoration should not be assumed to describe every SDK entry point.

Plan-file restoration through `VDt` is independent of deciding the permission
mode. Normal resume hydration awaits the plan restoration before using the
messages. Source also contains a slash-resume invocation which does not await
that call immediately. That call ordering alone does not prove a user-visible
race.

Restoration can recover permission state without recovering plan content. An
implementation must distinguish an open planning session from a readable,
reviewable plan. The source does not justify synthesising missing content from
the fact that the mode is `plan`.

## 9. Compaction

The compaction attachment builder `xRe`, within `224047900:224051950`, is used
by full, partial and reactive compaction paths. The builder restores applicable
read-file and background-task context, then adds a plan reference and a full
Plan-mode reminder, followed by applicable skills, tool/MCP and hook context.

The plan reference reader `iqr` runs before the full reminder builder `Aet`.
`Aet` reads the permission mode from runtime state. The reminder includes the
applicable plan-file, custom instruction, workshop or no-file-host branch.

The flattening function `yU` at `224025728:224026050` assembles the new message
sequence in this order:

1. Boundary marker.
2. Summary messages.
3. Replacement messages, when supplied.
4. Messages preserved by the compaction operation.
5. Restored attachments.
6. Hook results.

Compaction changes model context; the permission mode also exists outside that
context. The explicit post-compaction reminder restores full planning
instructions even if an ordinary reminder would have been shorter.

Ordinary reminder cadence is computed by `n$n` near `224919960`: five user turns
between applicable reminders, with every fifth reminder full. Compaction has its
own full-reminder path and does not rely on waiting for that cadence. If the
plan file cannot supply content, a reminder cannot reconstruct the plan merely
from the active mode.

## 10. What remains to establish

The original research report treated too many questions as requiring live
sessions. The amended investigation resolved prompt selection, context assembly,
foreground/background defaults, dialogue cancellation, approval transitions,
resume and compaction through source inspection and isolated probes.

| Category                   | Established or remaining question                                                                                                                                                              | Narrowest additional evidence                                                                                                                                                      |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Resolved statically        | Branch precedence, phase instructions, role definitions, child assembly, tool resolution, model/effort precedence, cancellation ownership, approval outcomes, restoration and compaction order | No live inference is needed to understand these mechanisms. Reinspect if the binary changes.                                                                                       |
| Configuration input        | Which branch an existing process selected, and the exact effective child prompt/tool/model/effort payload                                                                                      | A non-secret snapshot of that process's launch arguments, selected environment, settings, feature values, catalogue and hook inputs, or its already-recorded request construction. |
| Model choice or quality    | Whether the parent delegates, its agent count, briefs, search breadth, foreground argument, design synthesis and quality                                                                       | An existing transcript for a specific choice; representative evaluation tasks for quality. Source cannot predict model output.                                                     |
| Remaining host interaction | Whether a particular remote response arrived, whether an external editor saved, and what a user selected                                                                                       | Request-scoped transport logs, a deterministic host fixture, editor result or UI event. No model call is needed to test those contracts.                                           |
| Arbitrary extensions       | Effects of a user's external hooks, skills or MCP tools                                                                                                                                        | Their definitions and inputs, followed by isolated execution where source alone is insufficient. The generic host cannot establish arbitrary external behaviour.                   |

The static findings are sufficient to specify the architecture and lifecycle.
Planning-quality acceptance is a separate activity. It should not be used as a
reason to leave deterministic execution paths unexplained.

### Corrections to the earlier report

- Normal Explore and Plan calls have fresh initial transcript context. Optional
  intent forwarding, environment context and later scoped instruction loading
  qualify that description.
- Delegation counts belong to prompt construction. The generic runtime has a
  separate concurrency limit.
- Generic Agent calls default to background under ordinary top-level inputs. The
  source does not establish the optional arguments selected by the model in a
  particular planning run.
- Question cancellation is request-scoped. Pending-map deletion and a shared
  single-winner guard reject late answers and duplicate completion.
- Clear-context approval creates a new conversation identity in the existing
  process and preserves the plan association across that reset.
- Resume and compaction restoration are statically traceable. Their remaining
  variability is explicit configuration or external input. A paid model session
  is not needed to establish those mechanisms.

## Appendix A. Embedded-source evidence index

All ranges below refer to the exact executable and SHA-256 in section 1. The
index deliberately includes identifiers and offsets. The index does not
reproduce the full proprietary prompts.

| Topic                                 | Byte range            |
| ------------------------------------- | --------------------- |
| `build-metadata`                      | `217566000:217567000` |
| `parent-phases-and-reminders`         | `225726750:225740600` |
| `delegation-counts`                   | `225645157:225645520` |
| `builtin-explore-and-plan`            | `221026700:221033900` |
| `explore-plan-switch`                 | `220971300:220972000` |
| `subagent-steering`                   | `214962700:214965200` |
| `enter-plan-tool`                     | `229262000:229268000` |
| `exit-plan-tool`                      | `228884000:228893800` |
| `question-schema-and-tool`            | `229279400:229295200` |
| `question-prompt`                     | `218857200:218860900` |
| `generic-tool-default-permissions`    | `217129643:217132700` |
| `subagent-context-and-runtime`        | `228996300:229023600` |
| `subagent-tool-resolution`            | `229036281:229043700` |
| `subagent-delegation`                 | `229118300:229160000` |
| `subagent-effort`                     | `229079955:229081100` |
| `subagent-thinking-display`           | `215267799:215268100` |
| `intent-forwarding`                   | `215385000:215398300` |
| `subagent-errors-and-partial-results` | `229054900:229058500` |
| `plan-files-storage-and-recovery`     | `217161000:217178500` |
| `plan-file-write-carveout`            | `217565157:217565500` |
| `write-permissions`                   | `217601200:217603600` |
| `write-exemptions`                    | `217606549:217608350` |
| `plan-mode-entry-and-auto-state`      | `229222348:229223100` |
| `plan-mode-attachments`               | `224932400:224938100` |
| `reminder-cadence`                    | `224919960:224920050` |
| `compaction-plan-restoration`         | `224050200:224051950` |
| `exit-and-reentry-rendering`          | `225751400:225752100` |
| `reentry-instructions`                | `225771500:225773100` |
| `approval-menu-and-transitions`       | `244348248:244360000` |
| `resume-mode-restoration`             | `247562000:247567000` |
| `subagent-concurrency`                | `223286240:223286400` |
| `parent-branch-precedence`            | `214963600:214965300` |
| `parent-branch-model-registration`    | `223450200:223450950` |
| `child-system-prompt-postamble`       | `223454428:223455900` |
| `child-environment-context`           | `222052754:222057200` |
| `question-dialog-UI-and-timeout`      | `244296300:244313000` |
| `dialog-type-defaults`                | `242376200:242388500` |
| `dialog-typed-adapter`                | `214800850:214802500` |
| `dialog-request-transport`            | `243269923:243271500` |
| `dialog-renderer-binding`             | `244456200:244457100` |
| `dialog-store`                        | `231827000:231831200` |
| `permission-one-winner-and-cancel`    | `242405550:242408300` |
| `permission-dialog-coordinator`       | `242421700:242432500` |
| `foreground-background-state`         | `225526396:225532000` |
| `agent-kill-and-termination`          | `225521131:225523300` |
| `abort-relay`                         | `214725774:214728300` |
| `agent-run-terminal-notifications`    | `229058200:229069800` |
| `clear-conversation-implementation`   | `235846600:235852700` |
| `clear-context-continuation-consumer` | `244551300:244553000` |
| `interactive-resume-wrapper`          | `229879800:229880450` |
| `interactive-resume-invocation`       | `229893100:229895300` |
| `slash-resume-invocation`             | `243453500:243457500` |
| `print-resume-invocations`            | `249093300:249103000` |
| `compaction-reassembly-order`         | `224047900:224051950` |
| `compaction-flattening`               | `224025728:224026050` |

## Appendix B. Isolated decision-function probes

Twenty-four named scenarios passed. The harness extracted the actual functions
from the identified binary, supplied explicit dependency stubs and executed the
functions with Node 24.21.0 using TypeScript type stripping. The tests did not
replace the decision functions with independent implementations. Stubs supplied
feature values, caller identity, permission modes, tool identities and transport
callbacks. They did not simulate a provider or terminal renderer.

| Extracted function boundary | Byte range            |
| --------------------------- | --------------------- |
| `dialog-transport`          | `243269914:243270984` |
| `single-winner`             | `242405639:242405777` |
| `execution-choice`          | `229113099:229113414` |
| `plan-count`                | `225645157:225645367` |
| `explore-count`             | `225645367:225645474` |
| `thinking-display`          | `215267799:215268050` |
| `plan-segment`              | `247564082:247565466` |
| `resume-choice`             | `247565978:247566556` |
| `approval-result`           | `244350355:244351095` |

The passing scenarios were:

- Dialogue without renderer cancels immediately.
- Pre-aborted dialogue never renders.
- Abort retracts request and refuses stale answers and updates.
- Accepted dialogue detaches abort listener and resolves once.
- Permission race claims once and resolves once.
- Ordinary agent defaults to background.
- Explicit foreground waits.
- Disabled background forces foreground.
- Teammate child defaults foreground.
- Headless child defaults foreground.
- Remote isolation forces async.
- Agent frontmatter can force background.
- Planning count defaults, account variants and override bounds.
- Headless display suppression preserves thinking configuration.
- Plan attachment opens segment.
- Explicit exit closes segment.
- Successful entry opens segment.
- Successful exit closes segment.
- Rejected exit keeps segment open.
- Recorded user plan mode opens segment.
- Later non-plan human turn prevents stale open inference.
- Team approval submission does not exit.
- Interactive plan restoration respects pinned mode, fork, successful exit and
  gate.
- Approval adapter binds edited text, returns rejection feedback and separates
  clear-context continuation.

These probes verify the stated input/output boundaries. UI rendering, external
editor behaviour, remote delivery and model decisions remain outside their
scope. The source call paths in the main report establish how the application
uses the extracted decisions.
