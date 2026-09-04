#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils findutils gnused mkpasswd sops
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Prompt for the user's host password, hash it, and encrypt the hash and the
# user SSH private key.
#
# `generate-host-keys` registers the matching public key with GitHub once the
# secrets repository has been pushed.
#
# Usage: generate-user-secrets <host> <secrets_dir> <keys_dir>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"
secrets_dir="${2}"
keys_dir="${3}"

cd "${secrets_dir}"

log_step "Setting login password for ${host}"
while true; do
	IFS= read -r -s -p "Enter passphrase for ${USER}@${host}: " pass
	echo

	if [[ -z "${pass}" ]]; then
		log_warn "an empty passphrase lets anyone log in, try again"
		continue
	fi

	IFS= read -r -s -p "Confirm passphrase: " pass2
	echo

	if [[ "${pass}" == "${pass2}" ]]; then
		break
	fi

	log_warn "passphrases do not match, try again"
done

# `-s` makes mkpasswd read the passphrase from stdin, which keeps it out of
# the process list. /proc/<pid>/cmdline is world readable on Linux.
hashed="$(printf '%s\n' "${pass}" | mkpasswd -m sha-512 -s)"

password_plaintext="$(make_secret_temp_file)"
echo "user-password-hash: ${hashed}" >"${password_plaintext}"
encrypt_yaml_file "${password_plaintext}" "${host}/host-user-password.yaml"
echo "    Created ${host}/host-user-password.yaml"

log_step "Encrypting user SSH private key"
ssh_key_plaintext="$(make_secret_temp_file)"
{
	# Store the private key as an indented YAML block scalar for sops.
	echo "ssh-private-key: |"
	sed 's/^/    /' "${keys_dir}/id_ed25519"
} >"${ssh_key_plaintext}"
encrypt_yaml_file "${ssh_key_plaintext}" "${host}/user-ssh-key.yaml"
echo "    Created ${host}/user-ssh-key.yaml"
