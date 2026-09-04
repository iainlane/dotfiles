---
paths:
  - "**/*.rs"
  - "**/Cargo.toml"
  - "**/Cargo.lock"
---

# Rust Conventions

## Dependencies

- Always use `cargo add` to add dependencies. Never edit `Cargo.toml` manually.

## Style

- Follow Rust's idioms and best practices.
- Where possible, implement Rust traits instead of doing things ad-hoc, e.g.
  `From`, `Display`, `Error`, etc.
- `pub(crate)` or private visibility by default. Only expose what is necessary.
- We have strict clippy settings. NEVER use `allow` or `deny` attributes to
  silence clippy warnings. Instead, fix the underlying issue.
  - If you are initialising a project, configure clippy to be strict.
- No program logic in index, `mod.rs`, `lib.rs`, or re-export files -- these are
  only for module declarations and re-exports.

## Errors

- Use `thiserror` for defining error types.
  - Have variants for different error cases.
  - Use `#[from]` for error conversions.
  - `map_err` should not be needed.
- Use `anyhow` for error handling in application code.

## CLI

- Use `clap` for command line argument parsing.
- Always parse straight to proper types.

## Observability

- Use `tracing` and `tracing-opentelemetry`.
- Add traces and spans throughout.
- Use events for significant occurrences.
- Log at appropriate levels.
- If outputting to a terminal, use a pretty formatter. Otherwise, use JSON.

## Testing

- Always use `pretty_assertions::assert_eq!` for equality assertions.
- Use `rstest` for parameterised tests.
- Use `assert_matches` for matching error variants and other sum types.
- Don't use `unwrap()` in tests: use `?` or `expect()` with a helpful message.
- Use structural assertions on full objects. Don't repeatedly assert on the same
  value -- assign it to a variable instead. For example:

  ```rust
  // Bad
  assert_eq!(1, foo.bar);
  assert_eq!(2, foo.baz);
  assert_eq!(3, foo.quux);

  // Good
  assert_eq!(Foo { bar: 1, baz: 2, quux: 3 }, foo);
  ```

- When working with slices, don't compare the length and then look at some
  items. Instead, write out the whole expected slice and compare that.

## Documentation

- All public items must have doc comments.
- Include doctests for all public functions and methods.
