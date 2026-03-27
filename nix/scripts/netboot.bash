#!/usr/bin/env bash

# Serve a host's netboot installer using the public keys currently loaded in
# ssh-agent.
#
# Usage: netboot <host> [args...]

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"
shift

ensure_repo_root

tmpdir="$(make_temp_dir)"

agent_keys=()
while IFS= read -r key; do
	[[ -n "${key}" ]] || continue
	agent_keys+=("${key}")
done < <(ssh-add -L 2>/dev/null || true)

if [[ ${#agent_keys[@]} -eq 0 ]]; then
	die "ssh-add -L returned no keys. Load a key into ssh-agent first or run nix run .#${host}-netboot manually."
fi

netboot_args=()
# The netboot app expects key files, so write each ssh-agent key into tmpdir.
for i in "${!agent_keys[@]}"; do
	key_file="${tmpdir}/key-${i}.pub"
	printf '%s\n' "${agent_keys[$i]}" >"${key_file}"
	netboot_args+=(--authorized-keys-file "${key_file}")
done

log_step "Serving netboot for ${host} with ${#agent_keys[@]} SSH key(s)"
nix run ".#${host}-netboot" -- "${netboot_args[@]}" "$@"
