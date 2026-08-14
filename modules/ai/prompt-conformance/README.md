# Prompt conformance

This suite measures how the repository's assembled agent prompt changes affect
real repository work. Nix supplies the shared Claude rules, every installed
output style, the named default output style from managed settings, pinned
Claude and Codex clients, fixture-specific tool environments, and the host
isolation program.

Claude Opus 5 performs candidate work. Repeated judgements use GPT-5.6 Terra at
high effort, while the cross-run prompt improver uses GPT-5.6 Sol at high
effort. These role-specific choices and client versions are retained with each
run, and the candidate's initialisation event must report the requested Opus
model.

Each fixture starts from an exact repository URL and revision. Claude receives a
short task drawn from a historical failure and works in an isolated checkout.
The suite retains its final response, normalised action trace, Git patch and
commits, a snapshot of every Git-visible file before verification, and
deterministic verification results. Codex then judges that evidence blindly
against outcome, process, and communication criteria. The judge sees the same
controlled prompt context as the candidate as evidence, while its working
directory remains neutral so the candidate repository cannot configure it.

Historical known-good and unchanged revisions validate the evaluator role in the
first sample of every prompt evaluation. In a prompt-improvement run that
includes each competing draft and both reserved legs, so no prompt is compared
against another through an unvalidated evaluator. Further samples of the same
evaluation use that evaluator configuration for independent blind judgements
without repeating the reference calls. Process criteria apply to live runs
because they require the candidate's real action trace. The reference subjects
are opaque to the evaluator, so it must reach the expected decisions from the
same evidence interface used for live work.

## Running the suite

Choose a result directory. Reusing it resumes the same run:

```console
nix run .#claude-prompt-conformance -- ./prompt-results
```

On a terminal, Rich presents a catalogue and selection menu, nested progress,
and a section for each completed test containing Claude's response, the
candidate's Git changelog, changed files, and deterministic check results. A
gate which only passed when it was retried is shown as flaky rather than as a
plain pass. Failed tests also show the candidate work beside the judge's
recommendation and counterfactual correction, then list the failed criteria.
Redirected output is JSON Lines. `--format rich` and `--format json` select
either form explicitly. While Claude is working, its phase names the current
tool operation, reports how long that operation has been active, and labels SDK
progress records as heartbeats rather than completed work. The heartbeat age
keeps advancing when no new signal arrives. Parent rows aggregate concurrent
phases and active operations, so the display distinguishes a busy run from one
which is merely still alive. The numeric `x/y` count describes immediate
children only. The bar uses each child's declared share of its parent and
includes that child's recursive progress without changing the count. Open-ended
tasks use a pulsing bar and say, for example, `2 complete`, without inventing a
denominator.

Interrupting a run with Ctrl-C stops it gracefully: a notice appears above the
progress tree, agent processes receive escalating stop signals, and evidence
already written stays resumable. A second Ctrl-C kills every agent process group
and exits immediately.

Tests may be selected by name, category, or tag:

```console
nix run .#claude-prompt-conformance -- \
  ./prompt-results dotfiles-numeric-owner

nix run .#claude-prompt-conformance -- \
  ./prompt-results --category repository-change --tag typescript
```

List the catalogue without making model requests:

```console
nix run .#claude-prompt-conformance -- --list
```

Prompt improvement uses the same fixtures and configuration:

```console
nix run .#claude-prompt-conformance -- \
  ./prompt-results --all --improve
```

The search is one round of three competing proposals, each measured over five
fresh samples per prompt evaluation. `--proposals COUNT` and `--samples COUNT`
can reduce those limits. Three fresh improvers read the same working-example
results at the same time, each asked to look from a different angle: instruction
clarity, process and verification behaviour, or the relationship between the
final response and the recorded work. Every draft that proposes a change is
built and evaluated concurrently with the others, and the accepted draft with
the largest decisive improvement wins the round. Ties are settled by the fewest
noise regressions and then by draft order, so the winner does not depend on
scheduling.

A draft is accepted when one fixture criterion gains at least three of its five
samples and no criterion loses two or more. Five samples make a single changed
sample uninformative, so one lost sample anywhere is treated as noise and a gain
smaller than three is not treated as an effect at all. The second half of the
rule stops a proposal from buying one decisive gain with a broad, shallow
decline. Each `acceptance.json` records, for every fixture criterion, the pass
counts on both sides, the net change, and whether the criterion was already
unstable on the current prompt, so a result carried by a flaky criterion is
visible rather than merely absorbed into a total. `improvement-summary.json`
carries the same evidence for every draft and names the winner.

A gate command which fails is run once more. A gate which then passes is
recorded as flaky, excluded from the acceptance decision, and still shown in
reports and retained in the result directory with both attempts' output. A gate
which fails twice is a real failure: it rejects a proposal which introduced it,
while a gate already failing on the comparison prompt does not reject anything
by itself.

Reserved examples check the original and winning prompts for regressions. The
original prompt is measured on them from the start of the run, concurrently with
the current-prompt evaluation and the tournament, so only the winner's reserved
evaluation waits for the tournament to finish. When no proposal is accepted, the
original reserved evidence is still retained and reused by the next run.
Reserved evidence is unavailable to the improver, and reserved acceptance
requires only non-inferiority, using the same noise threshold. Once a reserved
result influences prompt design, that example should become a working example
and be replaced with a new reserved check. The production prompt remains
unchanged. A successful experiment writes `tries/winner.patch`, which can be
inspected and applied separately.

The result directory is positional and is also the durable run store. Repeating
the same command resumes it automatically: completed fixture results are reused,
and a fixture with complete candidate evidence continues at the judge. A
different set of controlled inputs is rejected. Versioned stores with a retained
input snapshot are upgraded in place. Evidence from an older unversioned store
is retained for inspection but rerun because it cannot be bound to the complete
fixture contract. Harness-only updates use the current executables without
changing the retained prompt, fixtures, or other experiment inputs.
`--unlink-first` removes only a directory carrying this suite's marker and
starts again. `--keep-workspaces` retains the checkouts alongside the durable
evidence, and `--skip-calibration` is available for ordinary local runs. Prompt
improvement checks the evaluator role against each fixture's references in the
first sample of every prompt evaluation, including each tournament draft and the
winner's reserved run, so no arm is measured by an unvalidated evaluator. Later
samples of the same evaluation reuse that evaluator configuration without
repeating the reference calls, and a resumed run reloads the retained
calibration instead of judging the references again; calibration is a validity
check, not model state carried between invocations.

One run-wide pool bounds how many agent processes are active at once, whatever
work asked for them: samples, fixtures, reference subjects, and competing drafts
all draw on the same pool, and `--jobs COUNT` sets its size, six by default.
Only candidate, judge, and improver invocations hold a slot; repository
preparation, evidence capture, and deterministic checks do not, so the limit
describes model concurrency rather than task concurrency. Interactive
improvement runs show each draft, prompt evaluation, sample, and fixture beneath
its parent task, with the samples of one evaluation and the drafts of one round
as siblings running together. Successful subtrees collapse into their parent
while failed or invalid work remains visible. Interrupting a run stops its
active process groups without a traceback and leaves completed and partial
artefacts in the result directory. A calibration failure in any sample also
cancels the rest of that evaluation instead of paying for measurements which
cannot be trusted.

## Evaluation and improvement

Each evaluator receives a fresh, neutral Codex working directory and a bespoke
read-only MCP server for that subject. Its schema-backed tools expose the
original task and criteria, final response, canonical Claude actions, Git patch
and commits, deterministic check results, controlled prompt, and candidate
workspace. Evidence is paged or listed so the evaluator can request the detail
needed for a criterion without placing every transcript and repository file in
its initial context. Codex returns a separate JSON-schema-constrained judgement.

Failed judgements identify the likely failure origin, show the work the
evaluator would have produced, provide a corrected final response, and record
prompt observations when the controlled prompt contributed. Each prompt improver
is a separate fresh Codex invocation. It receives the current prompt and
aggregated, structured working-example outcomes through a smaller MCP interface:
each failure's summary and recommendation, the per-criterion verdicts with their
reasons and cited evidence, the prompt observations, and the deterministic check
output. The evaluator's own counterfactual work and corrected response are
withheld, so a proposal must be reasoned from the recorded failures rather than
generalised from a model answer. An improver records the observations behind one
improvement theory, a short progress title, the intended change, reasoning,
risks, and either one general unified diff or an explicit decision that no
prompt change is warranted. Reserved-example evidence is never exposed through
this interface.

Ordinary run artefacts are grouped by fixture. They include the Claude event
stream and canonical action ledger, response, repository patch and commits,
verification output, judge events and structured judgement, MCP descriptor, and
isolation profiles. The result root also retains the complete controlled prompt
context and run metadata independently of the Nix store. At startup, the runner
also reads every immutable task, prompt, setting, schema, certificate, and
prompt-variant source into memory, then writes a private snapshot below
`.claude-prompt-conformance-state`. Later phases therefore do not depend on
those original Nix store paths remaining alive. Improvement runs group the same
evidence beneath the current-prompt evaluation, one `tries/draft-NN` directory
per competing draft holding its proposal, built prompt variant, results, and
acceptance record, and the reserved checks, with a final
`improvement-summary.json` naming the winner.

## Isolation

The domain layer declares readable paths, writable paths, hidden paths, and
network access. Seatbelt applies each declaration directly. Bubblewrap starts
from an empty root and mounts only the declared paths, so undeclared host paths
remain hidden without additional deny rules. Claude can write its instance
workspace, state, cache, and temporary directory, and has public network access
for realistic repository work. Codex can write its own state, cache, temporary
directory, and exact result file. It cannot read the host credential. The suite
starts the pinned client as an app server and supplies its current access token
through the external-auth protocol after the sandboxed process starts. Its model
permission profile denies filesystem and network access; the instance-specific
MCP server supplies the suite's evaluation or improvement evidence. The host
sandbox permits the Codex client to reach the model service, while its evidence
tree remains read-only. Nix supplies Codex with an explicit CA bundle through
`SSL_CERT_FILE`, and that bundle is also declared as a readable capability. This
keeps model TLS independent of macOS Security services, which the sandbox denies
to prevent credential access. Both platform adapters expose only runtime system
paths and the capabilities declared for an invocation. Codex reads the
host-managed configuration required by the client. The instance configuration
records an explicit disabled entry for every managed MCP server discovered
before the run and enables the suite's bespoke evidence server. Current Codex
configuration precedence can retain host-managed servers despite those instance
entries; isolating that managed layer is deliberately deferred. Bubblewrap also
supplies private PID, IPC, UTS, and device namespaces.

Seatbelt imports macOS's system runtime policy so dynamic executables can start,
and permits filesystem metadata for path resolution. File contents remain
limited to system runtime data and the paths declared by the invocation. A host
integration test starts the pinned Git through the real profile and verifies
that an undeclared file cannot be read or written. A separate opt-in probe makes
a real HTTPS connection through the same profile and explicit CA bundle.

Git uses a private home, disabled system and global configuration, a fixed
identity, disabled hooks, signing, credential helpers, terminal prompts, and SSH
commands. The run-scoped Codex authentication broker resolves the ordinary
client home from `CODEX_HOME`, with `~/.codex` as the client default, and owns
all access to its `auth.json`. When app-server reports a rejected access token,
the broker reloads the shared credential, adopts a rotation already completed by
another owner or competes for the refresh at the OAuth authority, and atomically
reconciles a successful response. If an ordinary Codex process wins that race,
the broker watches `auth.json` and adopts its completed write. Only the
resulting access token and account identifier cross the external-auth protocol;
refresh tokens are never written to instance state or result trees.
Configuration, cache, and temporary files remain private to each judge instance.
On macOS, PyObjC opens Claude's complete OAuth credential through the Security
framework when the run starts. One LocalAuthentication context is retained for
the run, so later credential reconciliation reuses that initial Keychain
authentication instead of prompting again. Linux loads the equivalent normal
Claude credentials file. The run retains that credential as a renewable session.
Candidate processes receive only the current access token through an inherited
file descriptor. If Claude rejects it, the candidate uses the pinned client's
bidirectional SDK protocol to request a fresh OAuth access token from the suite.
The suite coordinates through the pinned client's cross-process OAuth and
storage-write locks and reloads the shared credential only while reconciling a
refresh. It adopts a rotation completed by another process or safely persists
the complete newly rotated document, then returns only the access token.
Credential files, locks, and Keychain namespaces follow the pinned client's
secure-storage directory and custom-OAuth selection. Parallel candidates share
the same refresh operation and can continue across token rotations; credential
lifetime is not coupled to candidate runtime, and the suite sets no candidate
deadline. The macOS sandbox denies both Keychain service IPC and Claude's
redundant `security` prefetch process, so no OAuth secret enters the candidate
environment and candidates cannot trigger their own Keychain prompts.
Subscription-backed invocations have no dollar budget; API-backed invocations
receive the configured API budget. Claude receives private configuration, cache,
state, and temporary directories. The assembled rules and output styles are
linked into that private configuration. The suite omits production plugins and
marketplaces, loads no repository project settings, and supplies an empty strict
MCP configuration. Repository source text remains available as task context
because fixture revisions are reviewed inputs to the suite. The fixture's Nix
tool path and private temporary directory are applied through the run-specific
Claude settings, so they are available to model-run subprocesses. Claude runs
those commands through the pinned Nix Bash, keeping shell startup within the
declared environment.

The workspace snapshot is taken before deterministic checks run, so a formatter
or generator cannot rewrite the candidate evidence. Failed and interrupted
candidate instances are retained automatically for diagnosis. Prompt variants
use the host Nix daemon through the declared isolation capability, and each
variant carries prompt hashes generated from its own source tree.

## Fixture format

Each directory under `fixtures` contains `task.txt`, `case.json`, a vetted
positive response, and a negative response. `case.json` declares the repository,
short catalogue description, task kind, selection metadata, typed criteria,
preparation commands, deterministic commands, and calibration revisions. Review
fixtures can declare a comparison revision independently of the checked-out
revision. A process criterion sets `calibrate` to `false` when its evidence
exists only during a live agent run.

Fixture tasks contain the original problem evidence and a natural request to
investigate it. Solution constraints and output-style expectations belong to the
judge criteria, where they cannot coach the candidate.

## Implementation

The backend talks only to capability interfaces for instance allocation,
repository materialisation, prompt overlay installation, candidate execution,
workspace inspection, verification, judging, and events. Production composition
selects the platform adapter and concrete clients. Unit tests inject fakes for
every backend capability and compare complete domain structures. Platform tests
compare complete Seatbelt profiles and Bubblewrap commands. Nix runs Ruff,
pytest, import checks, package construction, wrapper construction, and a
non-interactive catalogue check without credentials or network access.

Three further Nix checks drive the pinned clients themselves. A protocol check
reads the effective configuration of an isolated Codex instance. A Codex
endpoint check completes a whole model turn against a scripted Responses
endpoint on loopback, so the packaged client, its code-mode host, and the
evidence MCP server are exercised together, and a client upgrade which severs
the chain from the model to the tools to the evidence fails a check instead of a
billed run. A Claude endpoint check likewise completes a real candidate turn,
including a tool permission denial, against a scripted Messages endpoint and
decodes every emitted stream record against this suite's schema; upstream
publishes no schema for that stream, so the check is what catches client drift.

A run also pins its own program closure. Startup reads every document input into
memory, but the pinned clients, the evidence MCP server, and the fixture
toolchains are executed from the Nix store throughout the run, so startup
registers an indirect garbage-collector root on the runtime configuration and
releases it on exit. The root's link lives in the session's runtime directory,
so a run that dies without cleaning up stops pinning when the session's
directory is cleaned, and Nix prunes the dangling automatic root at its next
collection.

Progress is an observable tree of scoped task runs. Each task owns its state,
children, parent relationship, and typed signal. Child changes propagate through
that relationship, and execution context supplies the parent when concurrent
work creates a child. A task declares one of three child policies. Fixed tasks
name every child and give it a relative weight; the weights are normalised to
the parent's whole progress region. Bounded tasks may discover up to a declared
maximum and reserve pessimistic space for every possible child until sealed.
Unbounded tasks remain indeterminate until sealed. Sealing either open policy
turns its discovered children into an ordinary determinate allocation.

Rich renders immutable tree snapshots with a spinner for every running task and
a progress bar for bounded work. Task changes only mark the frame dirty; a
ticker paints at 60 frames per second, skips frames whose fingerprint has not
changed, and wraps each paint in the terminal's synchronised-update mode so a
repaint never flickers. When the tree is taller than the terminal, the deepest
levels fold into their parents: a folded row summarises its children as one
glyph each and shows the most recent live operation among them, so a large run
stays visible on one screen at reduced detail. JSON mode serialises the same
typed task changes, allocations, current operations, and heartbeats without
introducing frontend concepts into the backend. Judge calibration exposes each
reference subject as a child task, so repository preparation, evidence capture,
deterministic checks, and judgement are visible instead of appearing as one
opaque wait.
