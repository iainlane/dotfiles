---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.svelte"
  - "**/*.js"
  - "**/*.jsx"
  - "**/package.json"
  - "**/tsconfig.json"
---

# TypeScript and Web Conventions

## General

- Always first determine which package manager (npm, yarn, pnpm) and runtime
  (node, bun, deno) is in use, so you know how to run commands in the project.
- Add and change dependencies with that package manager's own command
  (`npm install`, `pnpm add`, `yarn add`), never by hand-editing `package.json`.
- No program logic in `index.ts` or other re-export files: these are only for
  re-exports.
- Avoid `any` and unchecked casts unless there is no practical alternative.
- Use clear typed errors and never throw raw strings. Keep error messages
  actionable.

## Svelte

- Svelte 5's runes replaced the Svelte 4 reactivity model, and both syntaxes
  still appear in code and in search results. Read the project's own components
  and the current Svelte documentation before proposing changes, so the
  suggestion matches the version the project runs.

## TSDoc

- Prefer to include TSDoc comments for public APIs, but not for private ones.
  TSDoc comments should be used to explain the purpose of the API and how it
  should be used, not to describe the implementation details. Never simply
  repeat the name of the function as a comment. For a function named
  `sortArray`, the comment must not be "Sorts an array". Write something like
  "Given an array of numbers, returns a new array sorted in ascending order"
  instead.

## Web

- Keep a clean DOM. Avoid nesting as much as possible.
- Use semantic HTML elements.
- Use Tailwind for styling.
- Don't introduce any hardcoded colours or similar in the CSS. Refer to the
  project's design tokens (e.g. `app.css`) instead.
- Always consider and make components accessible.

## Testing

- Use vitest for unit and integration tests.
- Use msw to provide mock services.
- Write e2e tests with Playwright.
- Use `it.each` for parameterised tests.
- The whole-object assertion rule in `testing.md` looks like this in TypeScript:

  ```ts
  // Bad: hides missing or incorrect fields
  expect(result).toHaveLength(3);
  expect(result.every((r) => r.status === "ok")).toBe(true);

  // Good: any drift is immediately visible
  expect(result).toStrictEqual([
    { id: "a", status: "ok", value: 10 },
    { id: "b", status: "ok", value: 20 },
    { id: "c", status: "ok", value: 30 },
  ]);
  ```
