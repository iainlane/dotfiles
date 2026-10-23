import { expect, it } from "vitest";
import { parseGitStatus } from "../src/git.ts";

it("counts porcelain-v2 paths without parsing path contents", () => {
  expect(
    parseGitStatus(
      "# branch.head main\n# branch.ab +6 -2\n1 M. N... x x x x x staged\n1 .M N... x x x x x changed\nu UU N... x x x x x conflict\n? new file\n",
      100,
    ),
  ).toStrictEqual({
    branch: "main",
    staged: 1,
    unstaged: 1,
    untracked: 1,
    conflicts: 1,
    ahead: 6,
    behind: 2,
    root: "",
    worktree: undefined,
    operation: undefined,
    updatedAt: 100,
    stale: false,
  });
});
