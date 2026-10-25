import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";
import { text } from "./text.ts";

export interface GitState {
  branch: string;
  staged: number;
  unstaged: number;
  untracked: number;
  conflicts: number;
  ahead: number;
  behind: number;
  root: string;
  worktree: string | undefined;
  operation: string | undefined;
  updatedAt: number;
  stale: boolean;
}

export function parseGitStatus(output: string, now: number): GitState {
  const state: GitState = {
    branch: "",
    staged: 0,
    unstaged: 0,
    untracked: 0,
    conflicts: 0,
    ahead: 0,
    behind: 0,
    root: "",
    worktree: undefined,
    operation: undefined,
    updatedAt: now,
    stale: false,
  };
  let oid = "";

  for (const line of output.split("\n")) {
    if (line.startsWith("# branch.oid ")) {
      oid = line.slice(13, 21);
    }

    if (line.startsWith("# branch.head ")) {
      state.branch = text(line.slice(14));
    }

    const divergence = /^# branch.ab \+(\d+) -(\d+)$/.exec(line);

    if (divergence) {
      state.ahead = Number(divergence[1]);
      state.behind = Number(divergence[2]);
    }

    if (line.startsWith("? ")) {
      state.untracked++;
    }

    if (line.startsWith("u ")) {
      state.conflicts++;
    }

    if (/^[12] /.test(line)) {
      if (line[2] !== ".") {
        state.staged++;
      }

      if (line[3] !== ".") {
        state.unstaged++;
      }
    }
  }

  if (state.branch === "(detached)") {
    state.branch = `@${oid}`;
  }

  return state;
}

const execute = promisify(execFile);

async function git(cwd: string, args: string[]): Promise<string> {
  const result = await execute("git", args, {
    cwd,
    encoding: "utf8",
    timeout: 3000,
    maxBuffer: 2 * 1024 * 1024,
  });

  return result.stdout;
}

async function optional(path: string): Promise<string | undefined> {
  try {
    return (await readFile(path, "utf8")).trim();
  } catch (error) {
    if (
      error !== null &&
      typeof error === "object" &&
      "code" in error &&
      error.code === "ENOENT"
    ) {
      return undefined;
    }

    throw error;
  }
}

async function operation(dir: string): Promise<string | undefined> {
  const rebases = await Promise.all(
    ["rebase-merge", "rebase-apply"].map(
      async (folder): Promise<string | undefined> => {
        const current = await optional(
          join(dir, folder, folder === "rebase-merge" ? "msgnum" : "next"),
        );

        if (current === undefined) {
          return undefined;
        }

        const total = await optional(
          join(dir, folder, folder === "rebase-merge" ? "end" : "last"),
        );

        return `REBASE ${text(current, 8)}/${text(total, 8) || "?"}`;
      },
    ),
  );
  const rebase = rebases.find((value) => value !== undefined);

  if (rebase !== undefined) {
    return rebase;
  }

  const operations = await Promise.all(
    (
      [
        ["MERGE_HEAD", "MERGING"],
        ["CHERRY_PICK_HEAD", "CHERRY-PICKING"],
        ["REVERT_HEAD", "REVERTING"],
        ["BISECT_LOG", "BISECTING"],
      ] as const
    ).map(async ([file, label]) =>
      (await optional(join(dir, file))) === undefined ? undefined : label,
    ),
  );

  return operations.find((value) => value !== undefined);
}

export async function readGit(
  cwd: string,
  now: number,
): Promise<GitState | undefined> {
  let paths: string;

  try {
    paths = await git(cwd, [
      "rev-parse",
      "--path-format=absolute",
      "--git-dir",
      "--git-common-dir",
      "--show-toplevel",
    ]);
  } catch (error) {
    if (
      error instanceof Error &&
      error.message.includes("not a git repository")
    ) {
      return undefined;
    }

    throw error;
  }

  const [dir, common, root] = paths.trim().split("\n");

  if (
    dir === undefined ||
    dir === "" ||
    common === undefined ||
    common === "" ||
    root === undefined ||
    root === ""
  ) {
    throw new Error("Git returned incomplete repository paths");
  }

  const state = parseGitStatus(
    await git(cwd, [
      "status",
      "--porcelain=v2",
      "--branch",
      "--untracked-files=normal",
    ]),
    now,
  );

  state.root = text(dir === common ? root : dirname(common));
  state.worktree = dir === common ? undefined : text(basename(root));
  state.operation = await operation(dir);

  return state;
}
