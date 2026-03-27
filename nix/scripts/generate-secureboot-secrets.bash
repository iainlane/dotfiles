#!/usr/bin/env bash

# Generate and encrypt the secure boot PCR signing keypair for a host.
#
# Usage: generate-secureboot-secrets <host> <secrets_dir>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"
secrets_dir="${2}"

cd "${secrets_dir}"

log_step "Generating PCR signing keypair for secure boot"
pcr_private="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)"
pcr_public="$(printf '%s' "${pcr_private}" | openssl pkey -pubout 2>/dev/null)"

plaintext="$(make_temp_file)"
{
	# Persist both halves together so the host can sign and verify PCR policies.
	echo "pcr-signing-private.pem: |"
	printf '%s\n' "${pcr_private}" | sed 's/^/    /'
	echo "pcr-signing-public.pem: |"
	printf '%s\n' "${pcr_public}" | sed 's/^/    /'
} >"${plaintext}"

encrypt_yaml_file "${plaintext}" "${host}/host-secure-boot.yaml" "${host}/host-secure-boot.yaml"
echo "    Created ${host}/host-secure-boot.yaml"
