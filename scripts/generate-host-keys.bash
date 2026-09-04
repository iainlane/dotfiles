#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils findutils gh git
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Generate a new host's keys and secrets, update the secrets repository, and
# register the user's SSH key with GitHub.
#
# Every run makes a fresh SSH host key and a fresh user age key, so running it
# for a host that already has secrets replaces that host's identities.
# `write-host-secrets` refuses to do that without `--rekey`.
#
# Usage: generate-host-keys <host> <secrets_repo> [--rekey]

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"
secrets_repo="${2}"
shift 2

ensure_repo_root

keys_dir="$(mktemp -d)"

cleanup_keys_dir_on_failure() {
	local status="${1}"

	if [[ "${status}" -ne 0 ]]; then
		shred_tree "${keys_dir}"
	fi
}

# Keep generated private files only if the whole workflow finishes successfully.
register_exit_handler cleanup_keys_dir_on_failure

"${REPO_ROOT}/scripts/generate-keys.bash" "${host}" "${keys_dir}"

"${REPO_ROOT}/scripts/with-secrets-repo.bash" \
	"${secrets_repo}" \
	"feat: update keys and secrets for ${host}" \
	"${REPO_ROOT}/scripts/write-host-secrets.bash" "${host}" "${keys_dir}" "$@"

# The account gets the public key only after the secrets repository has the
# private half. The exit handler shreds the keys directory when the push
# fails, so registering first would leave a key on the account whose private
# half no longer exists.
log_step "Adding user SSH key to GitHub"
gh ssh-key add "${keys_dir}/id_ed25519.pub" --title "${USER}@${host}"
echo "    Added ${USER}@${host} to GitHub SSH keys"

echo
log_step "Keys generated successfully"
echo "    Keys directory: ${keys_dir}"
echo "    SSH host key:   ${keys_dir}/ssh_host_ed25519_key"
echo "    User SSH key:   ${keys_dir}/id_ed25519"
echo "    User age key:   ${keys_dir}/keys.txt"
echo
echo "    Use 'just install ${host} <target> ${keys_dir}' to deploy with these keys."
echo "    Keys will be injected via --extra-files and cleaned up after deployment."
