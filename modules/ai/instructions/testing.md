# Testing and Verification

## Testing

- Look through the project to see if it has tests before starting work. See if
  the tests apply to the code you're working on.
- If there are relevant tests:
  - Run them before making changes so you know what fails.
  - Add new tests for your changes, and make sure they pass when you're done.
  - Don't make excuses for your tests failing. If they fail, fix them. Tests
    must be reliable.
  - If it is possible, use TDD. First, write a test for the behaviour you are
    about to implement. Run it and make sure it fails. Then implement the
    behaviour and make the test pass.
- Use structural assertions on full objects. Output should be deterministic, so
  this ought to be possible. Don't repeatedly assert on the same value in tests
  -- assign it to a variable instead.
- Avoid writing repetitive tests: use parameterised tests instead.
- Use dependency injection via traits or interfaces to make code testable.
- Make sure to run the tests frequently during development.

## Verification

- After making code changes, execute the project-specific build, formatting,
  linting and type-checking commands (e.g. `tsc`, `npm run lint`,
  `ruff check .`, `cargo clippy`) that you have identified for this project (or
  obtained from the user). This ensures code quality and adherence to standards.
  If unsure about these commands, you can ask the user if they'd like you to run
  them and if so how to.
