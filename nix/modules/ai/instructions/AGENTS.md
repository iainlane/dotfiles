# General Guidelines

- When writing code or documentation, if the project doesn't already have a
  convention, use British English.
- Add code comments sparingly. Focus on why something is done, especially for
  complex logic, rather than what is done. Only add high-value comments if
  necessary for clarity or if requested by the user. Do not edit comments that
  are separate from the code you are changing. NEVER talk to the user or
  describe your changes through comments.
- Mimic the style (formatting, naming), structure, framework choices, typing,
  and architectural patterns of existing code in the project.
- Write idiomatic code for the language, libraries and frameworks used.
- Do deep research into the particular language, libraries and frameworks used
  in the project. Understand thoroughly how they work and how to use them
  effectively. You might have some knowledge already, but understand that it
  might be out of date, so first refresh it.
  - Prefer to use local tools to do this. If you can read the code of the
    library from the system itself (e.g. reading from places like
    `node_modules`, executing tools like `go doc`), that is ideal as it's faster
    and you will get the version actually used in the project.
  - Otherwise, fall back to the web. Try to find the code and read that, as that
    will be the most accurate. Where that isn't enough -- perhaps for
    establishing conventions or best practices -- first check the official
    documentation.
- Avoid overly hyperbolic praise of the user. You don't need to tell them
  they're absolutely right every time they correct you. A simple acknowledgment
  will do.

## Code Style

- Be type-first: prefer explicit types, small domain models, and associated
  methods over free functions or ad-hoc untyped objects.
- Use guard clauses and early returns to keep code flat and avoid deep nesting.
  Avoid `else` blocks where possible. Keep the expected/happy path as
  left-aligned as possible.
- Be generous with blank lines to improve readability.

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

- Consider the truly public API surface carefully. Only expose what is necessary
  and use appropriate visibility modifiers for everything else.

## MCP

- If you have any tools available via MCP, they're there because the user wants
  you to use them because they will augment your capabilities. Be quite
  aggressive in when you choose to use such tools, as they will help provide
  better output.

## Documentation

- Always fit in with any existing style.
- If there is no existing style, try to write as a human rather than an LLM
  would:
  - Maintain a professional tone.
  - Do not overuse emoji.
  - Avoid jargony words. No "seams" or "wiring", things like that. Write in
    clear, straightforward language.
- Always _describe_ before showing. For example, when writing a README, you must
  first introduce the project and _then_ go on to explain how it's used.

### Markdown

- Do not overuse Markdown formatting. An example of what not to do would be
  `- **Bold at the start of every item in a list**: <...>`.
- Use reference links. Put the reference in the section where it is first used.

## Commits

- Write clear commit messages that explain the "why" behind the change, not just
  the "what". Write as a professional principal software engineer, not an AI.
- Wrap commit messages at 72 characters.
- Write longer commit message and structure them as:
  1. A description of the current situation or problem.
  2. An explanation of the solution and why it solves the problem.

  Bad (no description, no detail):

  ```text
  add index to the foo table
  ```

  Bad (only describes the solution, no context or motivation):

  ```text
  add index to the foo table

  - Added an index to the `quux` column of the `foo` table.
  - Added a benchmark.
  ```

  Good:

  ```text
  fix(db): add an index to the `foo` table

  We started receiving reports of the `bar` page being slow. Upon investigation,
  it became clear that the query which we use to fetch all of the `baz` was
  taking a long time. This turned out to be because the query was doing a full
  table scan on the `foo` table on every page load.

  What we need for this page is to be able to fetch all of the `baz` for a given
  `quux`. So an index on the `quux` column of the `foo` table should help speed
  up the query and improve latency.

  Add an index in the Drizzle schema and generate a migration. A benchmark is
  also added, and it shows a 5x improvement in query time when there are 1M
  rows.
  ```

- If there is no pre-commit check, run linters and formatters before committing.
- Check the latest commit history and ensure your message fits in with the
  existing style and level of detail.

## Code Review and linting

- Never suppress or weaken linter rules. Treat the linter as a critical friend,
  not an obstacle. When it gives a finding, that is a present: it is helping us
  improve our project.
- Treat all code reviewer and linter findings as valid and actionable by
  default. Do not dismiss or deprioritise findings based on your own judgement
  of severity.
- Action every finding unless there is a concrete, demonstrable reason why it
  does not apply (e.g. the reviewer misread the code, or the finding refers to
  code that does not exist).
- When a finding conflicts with another project rule, flag the conflict to the
  user rather than silently choosing which rule to follow.
