#!/usr/bin/env bash
# Print the branch's commits ahead of and behind its upstream for the Claude
# Code status line, with a leading " · " separator, or nothing when there is no
# upstream or the branch is in sync.
#
# The working directory comes from the status-line JSON on stdin. Like the
# worktree helper, the output carries its own separator and collapses to
# nothing, so the segment hides via hideWhenEmpty and leaves no dangling
# separator in the git group.

input=$(cat)

dir=$(printf '%s' "${input}" | jq -r '.cwd // .workspace.current_dir // .workspace.project_dir // empty' 2>/dev/null) || exit 0

[ -n "${dir}" ] || exit 0

# No upstream: nothing to compare against.
git -C "${dir}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 || exit 0

counts=$(git -C "${dir}" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null) || exit 0

read -r ahead behind <<<"${counts}" || exit 0

[ -n "${ahead}" ] && [ -n "${behind}" ] || exit 0

out=""

if [ "${ahead}" -gt 0 ]; then
	out="↑${ahead}"
fi

if [ "${behind}" -gt 0 ]; then
	out="${out}↓${behind}"
fi

# In sync: nothing worth showing.
[ -n "${out}" ] || exit 0

printf ' · %s\n' "${out}"
