# Testing and Verification

## Testing

- Look through the project to see if it has tests before starting work. See if
  the tests apply to the code you're working on.
- If there are relevant tests:
  - Run them before making changes so you know what fails.
  - Add new tests for your changes, and make sure they pass when you're done.
  - Don't make excuses for your tests failing. If they fail, fix them. Tests
    must be reliable.
  - Use red/green TDD wherever the change allows it. Before implementing a
    behaviour or fixing a bug, write a test that describes the behaviour, run
    it, and confirm that it fails for the expected reason. Then implement the
    change and make the test pass. For a bug, the failing test is the evidence
    that the actual problem has been reproduced; a fix made without it may
    address a different problem.
- Size new tests like the neighbouring test files: roughly one focused test per
  behaviour the task states. Scratch scripts and quick checks are fine while
  working and need not be kept. Do not turn them into additional permanent test
  files.
- Assert on the whole object, not on one field at a time: a field that goes
  missing or changes then shows up in the failure. Test output should be
  deterministic, so a whole-object assertion is normally available. Where the
  same expression appears in several assertions, bind it to a variable and
  assert on that. `rust.md` and `typescript.md` show what this looks like in
  each language.
- Avoid writing repetitive tests: use parameterised tests instead.
- Use dependency injection via traits or interfaces to make code testable.
- Make sure to run the tests frequently during development.

## Verification

- After making code changes, run the project's build, formatting, linting and
  type-checking commands (e.g. `tsc`, `npm run lint`, `ruff check .`,
  `cargo clippy`). Find them in the project: its CI configuration, task runner,
  package manifest, or contributor documentation. If the project has none, say
  so in your summary. Do not stop to ask which commands to run.
