#!/usr/bin/env bash

# Install NixOS onto a remote target, optionally injecting generated set-up keys
# and secure boot files.
#
# Usage: install <host> <target> [keys_dir] [phases]

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"
target="${2}"
keys_dir="${3}"
phases="${4}"

ensure_repo_root

extra_files_args=()

if [[ -n "${keys_dir}" && -d "${keys_dir}" ]]; then
	log_step "Found pre-generated keys in ${keys_dir}"

	# nixos-anywhere can inject an ephemeral filesystem tree via --extra-files.
	extra_files_dir="$(make_temp_dir)"

	install -d -m 0755 "${extra_files_dir}/etc/ssh"
	install -m 0600 "${keys_dir}/ssh_host_ed25519_key" "${extra_files_dir}/etc/ssh/ssh_host_ed25519_key"
	install -m 0644 "${keys_dir}/ssh_host_ed25519_key.pub" "${extra_files_dir}/etc/ssh/ssh_host_ed25519_key.pub"

	user_age_dir="${extra_files_dir}/home/${USER}/.config/sops/age"
	install -d -m 0700 "${user_age_dir}"
	install -m 0600 "${keys_dir}/keys.txt" "${user_age_dir}/keys.txt"

	# Lanzaboote needs platform keys present during install so boot entries can be signed.
	log_step "Generating secure boot platform keys"
	for subdir in PK KEK db; do
		install -d -m 0700 "${extra_files_dir}/etc/secureboot/keys/${subdir}"
		openssl req -new -x509 -newkey rsa:2048 -nodes \
			-keyout "${extra_files_dir}/etc/secureboot/keys/${subdir}/${subdir}.key" \
			-out "${extra_files_dir}/etc/secureboot/keys/${subdir}/${subdir}.pem" \
			-subj "/CN=${host} ${subdir}/" -days 3650 2>/dev/null
		chmod 0600 "${extra_files_dir}/etc/secureboot/keys/${subdir}/${subdir}.key"
	done
	printf '%s' "$(uuidgen)" >"${extra_files_dir}/etc/secureboot/GUID"

	extra_files_args=(--extra-files "${extra_files_dir}")
	echo "    SSH host key, user age key, and secure boot keys will be injected"
elif [[ -n "${keys_dir}" ]]; then
	die "keys directory ${keys_dir} does not exist"
else
	log_step "No keys directory provided, proceeding without key injection"
	echo "    Run 'just generate-host-keys ${host}' first to set up keys"
fi

phases_args=()
if [[ -n "${phases}" ]]; then
	phases_args=(--phases "${phases}")
fi

log_step "Installing NixOS on ${host} via ${target}"
nix run .#nixos-anywhere -- \
	--flake ".#${host}" \
	--target-host "root@${target}" \
	--chown "/home/${USER}/.config" 1000:100 \
	"${phases_args[@]}" \
	"${extra_files_args[@]}"

if [[ -n "${keys_dir}" && -d "${keys_dir}" ]]; then
	log_step "Cleaning up ephemeral keys"
	shred_tree "${keys_dir}"
	echo "    Keys removed from ${keys_dir}"
fi
