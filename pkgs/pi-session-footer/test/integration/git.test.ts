import { expect, it } from "vitest";
import { execFileSync, spawnSync } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { readGit } from "#footer/integrations/git.ts";

it("counts paths and commits in the status of a checkout", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "pi-footer-git-"));
  const environment = {
    ...process.env,
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_AUTHOR_NAME: "Fixture",
    GIT_AUTHOR_EMAIL: "fixture@example.test",
    GIT_COMMITTER_NAME: "Fixture",
    GIT_COMMITTER_EMAIL: "fixture@example.test",
  };
  const git = (...args: string[]) =>
    spawnSync("git", ["-C", cwd, ...args], { env: environment });
  const commit = async (file: string, content: string) => {
    await writeFile(join(cwd, file), content);
    git("add", file);
    git("commit", "--quiet", `--message=${file}`);
  };

  try {
    git("init", "--quiet", "--initial-branch=fixture");
    await commit("conflict", "base\n");
    await commit("staged", "base\n");
    await commit("changed", "base\n");
    git("branch", "upstream");
    await commit("conflict", "ours\n");
    await commit("ahead", "ours\n");
    git("checkout", "--quiet", "upstream");
    await commit("conflict", "theirs\n");
    git("checkout", "--quiet", "fixture");
    git("branch", "--quiet", "--set-upstream-to=upstream");
    git("merge", "--quiet", "upstream");
    await writeFile(join(cwd, "staged"), "staged\n");
    git("add", "staged");
    await writeFile(join(cwd, "changed"), "changed\n");
    await writeFile(join(cwd, "untracked"), "untracked\n");

    expect(await readGit(cwd, 100)).toStrictEqual({
      branch: "fixture",
      staged: 1,
      unstaged: 1,
      untracked: 1,
      conflicts: 1,
      ahead: 2,
      behind: 1,
      root: await realpath(cwd),
      worktree: undefined,
      operation: "MERGING",
      updatedAt: 100,
      stale: false,
    });
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
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

it("reads status without rewriting the index of a stale checkout", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "pi-footer-git-"));

  try {
    const git = (...args: string[]) =>
      execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" });
    git("init", "--quiet", "--initial-branch=fixture");
    await writeFile(join(cwd, "tracked"), "content\n");
    git("add", "tracked");
    git(
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "--quiet",
      "--message=fixture",
    );
    await utimes(join(cwd, "tracked"), 1, 1);
    const index = join(cwd, ".git", "index");
    const before = await readFile(index);
    await readGit(cwd, 100);

    expect(await readFile(index)).toStrictEqual(before);
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
});
