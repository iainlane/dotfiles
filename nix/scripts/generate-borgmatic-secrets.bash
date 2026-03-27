#!/usr/bin/env bash

# Generate and encrypt the borgmatic backup passphrase for a host.
#
# Usage: generate-borgmatic-secrets <host> <secrets_dir>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"
secrets_dir="${2}"

cd "${secrets_dir}"

log_step "Generating borgmatic encryption passphrase"
borg_passphrase="$(openssl rand -base64 32)"

plaintext="$(make_temp_file)"
echo "encryption_passphrase: ${borg_passphrase}" >"${plaintext}"
encrypt_yaml_file "${plaintext}" "${host}/host-borgmatic.yaml" "${host}/host-borgmatic.yaml"
echo "    Created ${host}/host-borgmatic.yaml"
