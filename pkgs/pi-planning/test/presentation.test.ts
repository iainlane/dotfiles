import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { expect, it } from "vitest";
import { displayPath, displayText } from "../src/presentation.ts";

it.each([
  { path: homedir(), expected: "~" },
  {
    path: join(homedir(), ".pi", "agent", "plans", "draft.md"),
    expected: "~/.pi/agent/plans/draft.md",
  },
  {
    path: join(dirname(homedir()), "sibling", "draft.md"),
    expected: join(dirname(homedir()), "sibling", "draft.md"),
  },
  {
    path: "relative\tpath\nname.md",
    expected: "relative\\u0009path\\u000aname.md",
  },
])(
  "displays paths without prefix collisions or layout controls: $path",
  ({ path, expected }) => {
    expect(displayPath(path)).toBe(expected);
  },
);

it("preserves document layout and Unicode while exposing terminal controls", () => {
  expect(displayText("日本語 🦉\n\t\u001B[8mhidden\u009B0m")).toBe(
    "日本語 🦉\n\t\\u001b[8mhidden\\u009b0m",
  );
});
