#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils findutils openssl sops yq-go
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

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

plaintext="$(make_secret_temp_file)"

# Persist both halves together so the host can sign and verify PCR policies.
# Command substitution dropped the trailing newline openssl wrote, and a PEM
# file ends with one, so put it back.
PCR_PRIVATE="${pcr_private}" \
	PCR_PUBLIC="${pcr_public}" \
	yq -n '
        ."pcr-signing-private.pem" = strenv(PCR_PRIVATE) + "\n" |
        ."pcr-signing-public.pem" = strenv(PCR_PUBLIC) + "\n"
    ' >"${plaintext}"

encrypt_yaml_file "${plaintext}" "${host}/host-secure-boot.yaml"
echo "    Created ${host}/host-secure-boot.yaml"
