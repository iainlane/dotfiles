# General Guidelines

- Follow the project's existing formatting, naming, structure, framework
  choices, typing conventions, and architectural patterns.
- Treat existing code conventions and existing prose differently:
  - Existing code is authoritative for naming, terminology, formatting,
    structure, architecture, APIs, and documentation layout.
  - For comments, documentation, commit messages, and other prose, follow the
    active output style. Do not reproduce awkward prose merely because similar
    wording already exists in the repository.
- Write idiomatic code for the language, libraries and frameworks used.
- Do deep research into the particular language, libraries and frameworks used
  in the project. Understand thoroughly how they work and how to use them
  effectively. Existing knowledge may be out of date, so verify behaviour that
  matters to the implementation.
  - Prefer local tools and sources when possible. Reading the installed library
    source, `node_modules`, generated API information, or tools such as `go doc`
    gives the version actually used by the project.
  - Otherwise, use upstream source. Where source is not enough for conventions
    or intended usage, consult the official documentation.
- Do not edit comments, documentation, or other prose that is separate from the
  code you are changing unless the task calls for that cleanup.
- If a `.envrc` file is present in the project root and has already been
  allowed, activate it if it is not already active.
- If required system tools such as compilers, runtimes, or utilities are not in
  `PATH`, try `nix run`.

## Code Style

- Be type-first: prefer explicit types, small domain models, and associated
  methods over free functions or ad-hoc untyped objects.
- Use guard clauses and early returns to keep code flat and avoid deep nesting.
  Avoid `else` blocks where possible. Keep the expected or happy path as
  left-aligned as possible.
- Be generous with blank lines where they improve readability.

  Good:

  ```rust
  fn foo() {
      let bar = 1;

      if bar > 0 {
          do_something();
      }

      let baz = do_something_else();
      quux(baz)
  }
  ```

- Consider the truly public API surface carefully. Expose only what is
  necessary and use appropriate visibility modifiers for everything else.

## MCP

- If relevant tools are available through MCP, use them aggressively when they
  can provide information, context, or capabilities that improve the result.

## Documentation

- Follow the project's existing documentation structure, formatting, and
  organisation.

### Markdown

- Use reference links. Put the reference definitions in the section where they
  are first used.

## Commits

- Before writing a commit message, inspect the recent commit history and follow
  the repository's subject format and other commit conventions.
- Wrap commit messages at 72 characters unless the repository uses another
  convention.
- If there is no pre-commit check, run the relevant linters and formatters
  before committing.

## Code Review and Linting

- Never suppress or weaken linter rules merely to make a finding disappear.
  Treat a lint finding as evidence that the code should be reconsidered, not
  as an obstacle to work around.
- Do not satisfy a linter through a superficial structural workaround whose
  only purpose is to silence the rule. Fix the underlying design or structure
  that caused the finding.
- Treat all code-review and linter findings as valid and actionable by default.
  Do not dismiss or deprioritise a finding based only on your own judgement of
  severity. Understand the intent behind a rule's existence and fix the spirit
  as well as the letter. Example: a rule which forbids more than a certain
  number of function parameters could be satisfied by putting all parameters in
  to a single struct in all cases, but that would often be a superficial
  workaround to a more fundamental design problem.
- When a finding conflicts with another project rule, flag the conflict to the
  user rather than choosing which rule to follow yourself.
