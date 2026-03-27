#!/usr/bin/env bash

# Sync nixbuild.net account substituters and trusted keys from this repo's
# shared cache settings.
#
# Usage: sync-nixbuild-substituters

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

ensure_repo_root

tmp="$(make_temp_file)"

mapfile -t substituters < <(
	nix eval --json -f ./lib/nix/cache-settings.nix binaryCaches |
		nix run nixpkgs#jq -- -r 'to_entries[] | (.value.substituter // ("https://" + .key))'
)
mapfile -t trusted_public_keys < <(
	nix eval --json -f ./lib/nix/cache-settings.nix binaryCaches |
		nix run nixpkgs#jq -- -r 'to_entries[] | ((.value.publicKeyName // .key) + "-1:" + .value.key)'
)

{
	echo "settings substituters --reset"
	for substituter in "${substituters[@]}"; do
		printf 'settings substituters --add %q\n' "${substituter}"
	done

	echo "settings trusted-public-keys --reset"
	for trusted_public_key in "${trusted_public_keys[@]}"; do
		printf 'settings trusted-public-keys --add %q\n' "${trusted_public_key}"
	done

	echo "settings substituters --show"
	echo "settings trusted-public-keys --show"
	echo "exit"
} >"${tmp}"

log_step "Syncing nixbuild.net account cache settings"
ssh -T nixbuild-admin <"${tmp}"
