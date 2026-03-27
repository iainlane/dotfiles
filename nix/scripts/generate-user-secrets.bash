#!/usr/bin/env bash

# Prompt for the user's host password, encrypt it and the user SSH key, and
# register the SSH key with GitHub.
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
	IFS= read -r -s -p "Confirm passphrase: " pass2
	echo
	if [[ "${pass}" == "${pass2}" ]]; then
		break
	fi
	log_warn "passphrases do not match, try again"
done

hashed="$(mkpasswd -m sha-512 "${pass}")"

password_plaintext="$(make_temp_file)"
echo "user-password-hash: ${hashed}" >"${password_plaintext}"
encrypt_yaml_file "${password_plaintext}" "${host}/host-user-password.yaml" "${host}/host-user-password.yaml"
echo "    Created ${host}/host-user-password.yaml"

log_step "Encrypting user SSH private key"
ssh_key_plaintext="$(make_temp_file)"
{
	# Store the private key as an indented YAML block scalar for sops.
	echo "ssh-private-key: |"
	sed 's/^/    /' "${keys_dir}/id_ed25519"
} >"${ssh_key_plaintext}"
encrypt_yaml_file "${ssh_key_plaintext}" "${host}/user-ssh-key.yaml" "${host}/user-ssh-key.yaml"
echo "    Created ${host}/user-ssh-key.yaml"

log_step "Adding user SSH key to GitHub"
gh ssh-key add "${keys_dir}/id_ed25519.pub" --title "${USER}@${host}"
echo "    Added ${USER}@${host} to GitHub SSH keys"
