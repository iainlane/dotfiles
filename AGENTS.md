# Repository instructions

## Nix validation

Use Git flake references for local validation: `.` or `.#...`. Do not use
`path:.`, because it includes ignored working-tree files in the flake source and
can change how checks run.

Before validating a change with new files, run
`git add --intent-to-add -- path/to/file` for each new file in the change. Git
flake sources then include the file without staging its contents. Use explicit
paths and leave unrelated untracked files alone.

Run Nix commands through `direnv exec .` when the allowed `.envrc` is not
already active.

`./scripts/check-evaluation.bash` evaluates every host profile and planned CI
target with import-from-derivation disabled. Evaluation must not build packages,
even when their outputs are cached. Local validation, pre-commit and the
Cupboard workflows use the policy in `lib/nix/evaluation.conf`. The gate
enforces the policy after command-line options. Update workflows use the
cache-only settings in `nix.substituterConfig`.

`./just check` runs that evaluation gate, evaluates all configured systems and
builds checks for the native system. CI builds checks for every system through
the Cupboard target lists. Public validation uses native runners for each
system; publication uses the configured per-system cohorts and remote builders.

Checks remain available locally on every supported system. A check can set
`passthru.ci.runOnce = true` when CI should run one instance on the validation
system defined in `lib/ci.nix`. The deployment schema uses this policy;
activation checks remain on each host's system.
