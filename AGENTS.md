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

`./just check` evaluates all configured systems and builds checks for the native
system. It does not build checks for other systems. CI builds checks for every
system through the Cupboard target lists. Public validation uses native runners
for each system; publication uses the configured per-system cohorts and remote
builders.
