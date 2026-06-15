#!/usr/bin/env bash
# Print the current git worktree for the Claude Code status line, but only for
# a linked worktree. The primary worktree reports as "main", which duplicates
# the branch widget, so it is dropped.
#
# The working directory comes from the status-line JSON on stdin (the same
# data ccstatusline feeds custom commands). Worktree identity mirrors
# ccstatusline's own git-worktree widget: `git rev-parse --git-dir` is ".git"
# for the primary tree and ".git/worktrees/<name>" for a linked one.
#
# The output carries its own leading " · " separator and collapses to nothing
# when there is no linked worktree, so the segment hides via hideWhenEmpty and
# leaves no dangling separator in the git group.

input=$(cat)

dir=$(printf '%s' "${input}" | jq -r '.cwd // .workspace.current_dir // .workspace.project_dir // empty' 2>/dev/null) || exit 0

[ -n "${dir}" ] || exit 0

gitdir=$(git -C "${dir}" rev-parse --git-dir 2>/dev/null) || exit 0

norm=${gitdir//\\//}

case "${norm}" in
# primary worktree — nothing worth showing
.git | */.git)
	exit 0
	;;
*/worktrees/*)
	name=${norm##*/worktrees/}
	;;
*)
	exit 0
	;;
esac

name=${name%%/*}

[ -n "${name}" ] || exit 0

printf ' · 𖠰 %s\n' "${name}"
