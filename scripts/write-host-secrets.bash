#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils yq-go
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Write everything that a new host needs into a clone of the secrets
# repository: the sops recipients for its fresh identities, then the files from
# the per-feature generators.
#
# `generate-host-keys` runs this through `with-secrets-repo`, which clones the
# repository, passes the clone as the last argument, and commits and pushes
# whatever this writes.
#
# Usage: write-host-secrets <host> <keys_dir> [--rekey] <secrets_dir>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"
keys_dir="${2}"
secrets_dir="${*: -1}"
options=("${@:3:$#-3}")

rekey=false

for option in "${options[@]}"; do
	case "${option}" in
	--rekey)
		rekey=true
		;;

	*)
		die "unknown option ${option}"
		;;
	esac
done

# Whether the repository already has secrets for this host. Either a `<host>/`
# directory or a `<host>_host` anchor in `.sops.yaml` is enough; a host
# that was set up before has both.
host_is_known() {
	[[ -d "${host}" ]] && return 0

	yq -e '.keys[] | select(anchor == "'"${host}"'_host")' .sops.yaml >/dev/null 2>&1
}

host_age_pub="$(cat "${keys_dir}/host_age_pub")"
user_age_pub="$(cat "${keys_dir}/user_age_pub")"

cd "${secrets_dir}"

if [[ "${rekey}" == false ]] && host_is_known; then
	die "${host} already has secrets. Re-keying replaces its identities and its backup passphrase, so the archives already in the backup repository can no longer be decrypted. It also replaces the secure-boot PCR signing key, so the TPM enrolment on the machine stops unsealing. Pass --rekey to continue."
fi

log_step "Updating .sops.yaml with keys for ${host}"
# Replace any older entries for this host so running this again updates them cleanly.
yq -i '
    .keys = [.keys[] | select(anchor != "'"${host}"'_host" and anchor != "'"${host}"'_user")] |
    .creation_rules = [.creation_rules[] | select(.path_regex != "^'"${host}"'/host-.*\\.yaml$" and .path_regex != "^'"${host}"'/user-.*\\.yaml$")] |
    .keys += ["'"${host_age_pub}"'"] |
    .keys[-1] anchor = "'"${host}"'_host" |
    .keys += ["'"${user_age_pub}"'"] |
    .keys[-1] anchor = "'"${host}"'_user" |
    .creation_rules += [{
        "path_regex": "^'"${host}"'/host-.*\\.yaml$",
        "key_groups": [{"age": []}]
    }] |
    .creation_rules[-1].key_groups[0].age[0] alias = "'"${host}"'_host" |
    .creation_rules += [{
        "path_regex": "^'"${host}"'/user-.*\\.yaml$",
        "key_groups": [{"age": []}]
    }] |
    .creation_rules[-1].key_groups[0].age[0] alias = "'"${host}"'_user" |
    .keys |= sort_by(anchor) |
    .creation_rules |= sort_by(.path_regex)
' .sops.yaml

mkdir -p "${host}"

"${REPO_ROOT}/scripts/generate-secureboot-secrets.bash" "${host}" "${secrets_dir}"
"${REPO_ROOT}/scripts/generate-borgmatic-secrets.bash" "${host}" "${secrets_dir}"
"${REPO_ROOT}/scripts/generate-user-secrets.bash" "${host}" "${keys_dir}" "${secrets_dir}"
