#!/usr/bin/env bash

# Generate the SSH and age keys needed to set up a new host.
#
# Usage: generate-keys <host> <keys_dir>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"
keys_dir="${2}"

mkdir -p "${keys_dir}"

log_step "Generating SSH host key for ${host}"
ssh-keygen -t ed25519 -N "" -C "root@${host}" -f "${keys_dir}/ssh_host_ed25519_key"

log_step "Deriving age public key from SSH host key"
host_age_pub="$(ssh-to-age <"${keys_dir}/ssh_host_ed25519_key.pub")"
echo "${host_age_pub}" >"${keys_dir}/host_age_pub"
echo "    Host age public key: ${host_age_pub}"

log_step "Generating user SSH key for ${USER}@${host}"
ssh-keygen -t ed25519 -N "" -C "${USER}@${host}" -f "${keys_dir}/id_ed25519"
echo "    User SSH public key: $(cat "${keys_dir}/id_ed25519.pub")"

log_step "Generating user age key for ${USER}"
age_out="$(age-keygen 2>&1)"
echo "${age_out}" | grep '^AGE-SECRET-KEY' >"${keys_dir}/keys.txt"
chmod 0600 "${keys_dir}/keys.txt"
user_age_pub="$(echo "${age_out}" | grep 'public key' | sed 's/.*: //')"
echo "${user_age_pub}" >"${keys_dir}/user_age_pub"
echo "    User age public key: ${user_age_pub}"
