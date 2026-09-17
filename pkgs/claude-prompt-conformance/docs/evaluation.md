# Evaluation

How a run captures candidate evidence, how that evidence is judged, and how
results are stored and resumed.

## Candidate evidence

Each fixture starts from an exact repository URL and revision. Claude receives a
short task drawn from a historical failure and works in an isolated checkout.
The suite retains its final response, a normalised action trace, the Git patch
and commits, a snapshot of every Git-visible file, and deterministic
verification results. The snapshot is taken before the deterministic checks run,
so a formatter or generator invoked during verification cannot rewrite the
candidate evidence.

The candidate must be the requested model: its initialisation event is checked
against the model the managed settings select. The model chosen for each role
and the pinned client versions are recorded with every run.

## Judging

Codex judges the evidence blindly against the fixture's outcome, process, and
communication criteria. The judge and the improver each run at high effort on
the models that the package and the `ai` feature configure for those roles (see
[improvement.md]).

Each evaluator receives a fresh, neutral Codex working directory and a bespoke
read-only MCP server for its subject. The server's schema-backed tools expose
the original task and criteria, the final response, the canonical Claude
actions, the Git patch and commits, the deterministic check results, the
controlled prompt, and the candidate workspace. Evidence is paged or listed, so
the evaluator can request detail one criterion at a time instead of loading
every transcript and repository file into its initial context. Codex returns a
separate JSON-schema-constrained judgement.

The judge sees the candidate's controlled prompt context, but only as evidence.
Its own working directory stays neutral, so the candidate repository cannot
configure the judge.

A failed judgement identifies the likely origin of the failure, shows what the
evaluator itself would have produced, provides a corrected final response, and
records prompt observations when the controlled prompt contributed to the
failure.

[improvement.md]: improvement.md

## Calibration

Historical known-good and unchanged revisions validate the evaluator role in the
first sample of every prompt evaluation. Further samples of the same evaluation
use that evaluator configuration for independent blind judgements without
repeating the reference calls, and a resumed run reloads the retained
calibration without judging the references again. Calibration is a validity
check, not model state retained between invocations.

The reference subjects are opaque to the evaluator, so it must reach the
expected decisions from the same evidence interface used for live work. Process
criteria are exempt because they require the candidate's real action trace; a
fixture marks such a criterion with `calibrate` set to `false`.

A calibration failure in any sample cancels the rest of that evaluation. An
unvalidated evaluator's measurements cannot be trusted, and cancelling stops the
run spending further model requests on them.

## Verification gates

A gate command which fails is run once more. A gate which then passes is
recorded as flaky, shown that way in reports, and retained in the result
directory with both attempts' output. A gate which fails twice is a real
failure.

## The result store

The result directory given on the command line is also the durable run store.
Repeating the same command resumes it: completed fixture results are reused, and
a fixture with complete candidate evidence continues at the judge. A different
set of controlled inputs is rejected.

The store format has a version, and that version is part of the run identity, so
a store written by an earlier version is rejected like one written from
different inputs. There is no upgrade path: the evidence stays on disk, and the
run has to start again in another directory or with `--unlink-first`, which
removes only a directory with this suite's marker. Harness-only updates use the
current executables without changing the retained prompt, fixtures, or other
experiment inputs.

At startup the runner reads every immutable task, prompt, setting, schema,
certificate, and prompt-variant source into memory, then writes a private
snapshot below `.claude-prompt-conformance-state`. Later phases therefore do not
depend on the original Nix store paths remaining alive.

## Concurrency

One run-wide pool bounds how many agent processes are active at once, whatever
work asked for them: samples, fixtures, reference subjects, and competing drafts
all draw on the same pool, and `--jobs` sets its size. Only candidate, judge,
and improver invocations take a slot; repository preparation, evidence capture,
and deterministic checks do not, so the limit counts concurrent model
invocations only.

## Run artefacts

Ordinary run artefacts are grouped by fixture. They include the Claude event
stream and canonical action ledger, the response, the repository patch and
commits, verification output, judge events and the structured judgement, the MCP
descriptor, and the isolation profiles. The result root also retains the
complete controlled prompt context and run metadata independently of the Nix
store. Failed and interrupted candidate instances are retained automatically for
diagnosis.
