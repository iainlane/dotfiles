import { expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { readGit } from "../src/git.ts";

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
      execFileSync("git", ["init", "--quiet", "--initial-branch=fixture", cwd]);
      await Promise.all(
        Object.entries(files).map(async ([file, value]) => {
          const path = join(cwd, ".git", file);
          await mkdir(dirname(path), { recursive: true });
          await writeFile(path, value);
        }),
      );
      const git = await readGit(cwd, 100);

      expect(git).toStrictEqual({
        branch: "fixture",
        staged: 0,
        unstaged: 0,
        untracked: 0,
        conflicts: 0,
        ahead: 0,
        behind: 0,
        root: await realpath(cwd),
        worktree: undefined,
        operation,
        updatedAt: 100,
        stale: false,
      });
    } finally {
      await rm(cwd, { recursive: true, force: true });
    }
  },
);
