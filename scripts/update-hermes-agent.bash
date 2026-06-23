#!/usr/bin/env bash

# Bump the hermes-agent flake input to the newest upstream release tag and
# re-lock it.
#
# The input is pinned to an immutable `vYYYY.M.D` tag, so `nix flake update`
# can never move it on its own. This asks GitHub for the latest release tag,
# rewrites the pinned URL in flake.nix, and updates the lock to match.
#
# Usage: update-hermes-agent

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

readonly repo="NousResearch/hermes-agent"
readonly input_name="${repo##*/}"
readonly flake_url="github:${repo}"

ensure_repo_root

if ! latest_tag="$(gh api "repos/${repo}/releases/latest" --jq .tag_name)"; then
	die "could not fetch the latest ${input_name} release from GitHub"
fi

current_url="$(grep -oE "${flake_url}/[^\"]+" flake.nix | head -n1)"
current_tag="${current_url##*/}"

if [[ "${current_tag}" == "${latest_tag}" ]]; then
	log_note "${input_name} is already on the latest release (${latest_tag})"
	exit 0
fi

log_step "Bumping ${input_name}: ${current_tag} -> ${latest_tag}"

tmp="$(make_temp_file)"
sed -E "s#(${flake_url})/[^\"]+#\1/${latest_tag}#" flake.nix >"${tmp}"
cat "${tmp}" >flake.nix

log_step "Re-locking ${input_name}"
nix flake update "${input_name}"
