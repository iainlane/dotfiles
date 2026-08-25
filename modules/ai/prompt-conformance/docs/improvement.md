# Prompt improvement

`--improve` runs a bounded search for a better prompt using the same fixtures
and configuration as an ordinary run. The production prompt is never changed: a
successful experiment writes `tries/winner.patch`, which can be inspected and
applied separately.

## The tournament

The search is one round of three competing proposals, each measured over five
fresh samples per prompt evaluation. `--proposals COUNT` and `--samples COUNT`
can reduce those limits.

Three fresh improvers read the same working-example results at the same time,
each asked to look from a different angle: instruction clarity, process and
verification behaviour, or the relationship between the final response and the
recorded work. Every draft which proposes a change is built and evaluated
concurrently with the others. The accepted draft with the largest decisive
improvement wins the round; ties are settled by the fewest noise regressions and
then by draft order, so the winner does not depend on scheduling.

Draft prompt variants are built with Nix during the run, and each variant
carries prompt hashes generated from its own source tree.

## What the improver sees

Each prompt improver is a separate fresh Codex invocation. It receives the
current prompt and aggregated, structured working-example outcomes through a
small MCP interface: each failure's summary and recommendation, the
per-criterion verdicts with their reasons and cited evidence, the prompt
observations, and the deterministic check output. The evaluator's own
counterfactual work and corrected response are withheld, so a proposal can only
be reasoned from the recorded failures. Reserved-example evidence is never
exposed through this interface.

An improver records the observations behind one improvement theory, a short
progress title, the intended change, its reasoning and risks, and either one
general unified diff or an explicit decision that no prompt change is warranted.

## Acceptance

A draft is accepted when one fixture criterion gains at least three of its five
samples and no criterion loses two or more. Five samples make a single changed
sample uninformative, so one lost sample anywhere is treated as noise; the
second half of the rule stops a proposal from buying one decisive gain with a
broad, shallow decline.

Each `acceptance.json` records, for every fixture criterion, the pass counts on
both sides, the net change, and whether the criterion was already unstable on
the current prompt, so a result carried by a flaky criterion stays visible.
`improvement-summary.json` carries the same evidence for every draft and names
the winner.

Flaky verification gates (see [evaluation.md]) are excluded from the acceptance
decision. A gate which fails twice rejects a proposal which introduced it, while
a gate already failing on the comparison prompt does not reject anything by
itself.

[evaluation.md]: evaluation.md

## Reserved examples

Reserved examples check the original and winning prompts for regressions. The
original prompt is measured on them from the start of the run, concurrently with
the current-prompt evaluation and the tournament, so only the winner's reserved
evaluation waits for the tournament to finish. When no proposal is accepted, the
original reserved evidence is still retained and reused by the next run.

Reserved acceptance requires only non-inferiority, using the same noise
threshold. Once a reserved result influences prompt design, that example should
become a working example and be replaced with a new reserved check.

## Calibration during improvement

The evaluator is checked against each fixture's references in the first sample
of every prompt evaluation, including each tournament draft and the winner's
reserved run, so no prompt is compared against another through an unvalidated
evaluator. Later samples of the same evaluation reuse that evaluator
configuration without repeating the reference calls.

## Artefacts

Improvement runs group the ordinary run evidence beneath the current-prompt
evaluation, with one `tries/draft-NN` directory per competing draft holding its
proposal, built prompt variant, results, and acceptance record, and the reserved
checks alongside. A final `improvement-summary.json` names the winner.
