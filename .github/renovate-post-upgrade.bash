#!/usr/bin/env bash
# Renovate runs this after each npm update. The npm rules in
# .github/renovate.json5 explain why it replaces Renovate's own relock.

set -euo pipefail

mapfile -t packages < <(
	git diff --name-only HEAD -- 'pkgs/*/package.json' 'pkgs/*/pnpm-workspace.yaml' |
		cut -d / -f 2 |
		sort -u
)

if ((${#packages[@]} == 0)); then
	exit 0
fi

NIX_CONFIG="${NIX_CONFIG:-}"$'\n'"$(nix eval --raw .#nix.substituterConfig)"
export NIX_CONFIG

for package in "${packages[@]}"; do
	# The update-<package> apps refuse to run while the package has uncommitted changes.
	nix run ".#${package}.passthru.updateScript"
done
