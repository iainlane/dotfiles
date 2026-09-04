#!/usr/bin/env bash

set -euo pipefail

relevant_paths=(
	flake.lock
	flake.nix
	.github/workflows/prompt-conformance.yml
	flake/parts/apps.nix
	flake/parts/git-hooks.nix
	features/ai/agent-instructions.nix
	features/ai/models.nix
	features/ai/claude-code/managed-settings-common.nix
	features/ai/output-styles.nix
	features/ai/instructions/
	features/ai/output-style/
	pkgs/claude-prompt-conformance/
	scripts/check-prompt-conformance.bash
)

# Pre-commit removes deleted paths from its filename list. Query Git directly
# so deletions affect selection in both the local index and a CI revision range.
if [[ -n "${PRE_COMMIT_FROM_REF:-}" && -n "${PRE_COMMIT_TO_REF:-}" ]]; then
	diff_source=("${PRE_COMMIT_FROM_REF}...${PRE_COMMIT_TO_REF}")
elif [[ -n "${PRE_COMMIT_FROM_REF:-}" || -n "${PRE_COMMIT_TO_REF:-}" ]]; then
	printf 'PRE_COMMIT_FROM_REF and PRE_COMMIT_TO_REF must be set together.\n' >&2
	exit 2
else
	diff_source=(--cached)
fi

set +e
git diff \
	--quiet \
	--exit-code \
	--diff-filter=ACMRD \
	"${diff_source[@]}" \
	-- \
	"${relevant_paths[@]}"
status=$?
set -e

case "${status}" in
0)
	exit 0
	;;
1)
	exec nix build --no-link "$@"
	;;
*)
	exit "${status}"
	;;
esac
