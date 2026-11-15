import type { GitState } from "#footer/integrations/git.ts";

export function gitState(
  branch: string,
  updatedAt: number,
  changes: Partial<GitState> = {},
): GitState {
  return {
    branch,
    staged: 0,
    unstaged: 0,
    untracked: 0,
    conflicts: 0,
    ahead: 0,
    behind: 0,
    root: "",
    worktree: undefined,
    operation: undefined,
    updatedAt,
    stale: false,
    ...changes,
  };
}
