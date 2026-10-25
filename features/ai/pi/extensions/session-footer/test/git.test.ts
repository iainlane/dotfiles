import { expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { parseGitStatus, readGit } from "../src/git.ts";

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

it.each<{ files: Record<string, string>; operation: string }>([
  {
    files: {
      "rebase-merge/msgnum": "2",
      "rebase-merge/end": "5",
      MERGE_HEAD: "fixture",
    },
    operation: "REBASE 2/5",
  },
  {
    files: { "rebase-apply/next": "1", "rebase-apply/last": "3" },
    operation: "REBASE 1/3",
  },
  {
    files: { CHERRY_PICK_HEAD: "fixture", REVERT_HEAD: "fixture" },
    operation: "CHERRY-PICKING",
  },
])(
  "detects Git operation metadata with its established priority: $operation",
  async ({ files, operation }) => {
    const cwd = await mkdtemp(join(tmpdir(), "pi-footer-git-"));

    try {
      execFileSync("git", ["init", "--quiet", cwd]);
      await Promise.all(
        Object.entries(files).map(async ([file, value]) => {
          const path = join(cwd, ".git", file);
          await mkdir(dirname(path), { recursive: true });
          await writeFile(path, value);
        }),
      );
      const git = await readGit(cwd, 100);

      expect(git?.operation).toBe(operation);
    } finally {
      await rm(cwd, { recursive: true, force: true });
    }
  },
);
