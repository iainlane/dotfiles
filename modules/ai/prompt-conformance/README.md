# Prompt conformance

![A demo run][demo]

This suite measures how changes to the repository's assembled agent prompt
affect real repository work. The prompt under test is the one Nix builds for
this repository: the shared Claude rules, the installed output styles, and the
default output style from managed settings.

Each fixture gives Claude a short task, drawn from a historical failure, in an
isolated checkout of a pinned repository revision. The suite records what Claude
did, and Codex judges that evidence blindly against the fixture's criteria. An
improvement mode proposes prompt changes and measures them with the same
fixtures.

Claude Opus 5 does the candidate work. GPT-5.6 Terra judges it, and GPT-5.6 Sol
writes improvement proposals. Nix pins the clients, the prompt inputs, and the
fixture tool environments, so two runs of the same fixtures differ only in the
prompt.

## Running the suite

Choose a result directory. It is the durable run store: repeating the same
command resumes the run and reuses completed fixture results.

```console
nix run .#claude-prompt-conformance -- ./prompt-results
```

On a terminal the suite presents a selection menu and live progress, then a
section for each completed test with Claude's response, its Git changelog,
changed files, and check results. Redirected output is JSON Lines; `--format`
selects either form explicitly.

Tests may be selected by name, category, or tag:

```console
nix run .#claude-prompt-conformance -- \
  ./prompt-results dotfiles-numeric-owner

nix run .#claude-prompt-conformance -- \
  ./prompt-results --category repository-change --tag typescript
```

`--list` prints the catalogue without making any model requests. `--demo` goes
further: it drives the whole display, from the selection menu to the finished
result sections, with scripted agents in place of real ones. A demo run reads no
credentials, opens no network connection, and makes no model requests, and its
evidence lives only in a temporary directory.

Ctrl-C stops a run gracefully, and evidence already written stays resumable. A
second Ctrl-C kills every agent process group and exits immediately.

`--jobs COUNT` bounds how many agent processes run at once (default six).
`--keep-workspaces` retains the checkouts alongside the evidence, and
`--unlink-first` removes a previous run store and starts again.

[demo]: docs/demo.webp

## Prompt improvement

```console
nix run .#claude-prompt-conformance -- \
  ./prompt-results --all --improve
```

An improvement run races three competing prompt drafts, measures each over five
fresh samples per fixture, and accepts a draft only on a decisive improvement
with no matching decline. The production prompt is never changed: a successful
experiment writes `tries/winner.patch`, which can be inspected and applied
separately. [docs/improvement.md] describes the tournament, the acceptance rule,
and the reserved regression checks.

[docs/improvement.md]: docs/improvement.md

## Fixtures

Each directory under `fixtures` contains `task.txt`, `case.json`, a vetted
positive response, and a negative response. `case.json` declares the repository,
a short catalogue description, the task kind, selection metadata, typed
criteria, preparation commands, deterministic commands, and calibration
revisions. Review fixtures can declare a comparison revision independently of
the checked-out revision. A process criterion sets `calibrate` to `false` when
its evidence exists only during a live agent run.

Fixture tasks contain the original problem evidence and a natural request to
investigate it. Solution constraints and output-style expectations belong to the
judge criteria, where they cannot coach the candidate.

## Further documentation

- [docs/evaluation.md] — the evidence a run captures, judging and calibration,
  and the result store.
- [docs/improvement.md] — the prompt-improvement tournament.
- [docs/isolation.md] — sandboxing and credential handling.
- [docs/architecture.md] — code structure, checks, and the progress model.

[docs/evaluation.md]: docs/evaluation.md
[docs/isolation.md]: docs/isolation.md
[docs/architecture.md]: docs/architecture.md
