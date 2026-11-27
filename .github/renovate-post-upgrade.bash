#!/usr/bin/env bash
# Renovate runs this after each npm update. The npm rules in
# .github/renovate.json5 explain why it replaces Renovate's own relock.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
scratch="$(mktemp -d)"
checkout="$scratch/checkout"
manifests=()

finish() {
	local status=$?
	if [[ -f "$checkout/.git" ]]; then
		git worktree remove --force "$checkout" || true
	fi
	rm -rf -- "$scratch"

	if ((status != 0 && ${#manifests[@]} > 0)); then
		# Renovate keeps the proposed manifest contents in memory and collects
		# files with working-tree changes even when the hook fails. Keep its
		# proposals in the index so Git reports the restored files as modified
		# and Renovate reads the original contents back. It resets the index
		# before preparing its commit.
		git --literal-pathspecs add -- "${manifests[@]}"
		git --literal-pathspecs restore --source=HEAD --worktree -- "${manifests[@]}"
	fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git diff --no-renames --diff-filter=M --name-only -z HEAD -- \
	':(glob)pkgs/**/package.json' ':(glob)pkgs/**/pnpm-workspace.yaml' >"$scratch/manifests"
mapfile -d '' -t manifests <"$scratch/manifests"
if ((${#manifests[@]} == 0)); then
	exit 0
fi

renovate_data="${RENOVATE_POST_UPGRADE_COMMAND_DATA_FILE:?Missing Renovate upgrade data}"

printf '%s\n' "${manifests[@]}" | cut -d / -f 2 | LC_ALL=C sort -u >"$scratch/packages"
mapfile -t packages <"$scratch/packages"

# Run the entire batch in a disposable checkout. Keep Renovate's proposed
# changes as the baseline for the patch we apply after all updaters succeed.
git diff --binary HEAD >"$scratch/input.patch"
git worktree add --quiet --detach "$checkout" HEAD
(
	cd "$checkout"
	git apply --index "$scratch/input.patch"
	input_tree="$(git write-tree)"

	NIX_CONFIG="${NIX_CONFIG:-}"$'\n'"$(nix eval --raw .#nix.substituterConfig)"
	export NIX_CONFIG

	for package in "${packages[@]}"; do
		nix run ".#${package}.passthru.updateScript" -- --renovate "$renovate_data"
	done

	git add -A -- pkgs
	git diff --binary "$input_tree" -- pkgs >"$scratch/output.patch"
)
if [[ -s "$scratch/output.patch" ]]; then
	git apply "$scratch/output.patch"
fi
