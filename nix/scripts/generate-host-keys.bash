#!/usr/bin/env bash

# Generate a new host's keys and secrets, update the secrets repo, and push the
# result.
#
# Usage: generate-host-keys <host> <secrets_repo>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"
secrets_repo="${2}"

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

host_age_pub="$(cat "${keys_dir}/host_age_pub")"
user_age_pub="$(cat "${keys_dir}/user_age_pub")"

log_step "Cloning secrets repo"
secrets_dir="$(make_temp_dir)"
clone_url="${secrets_repo#git+}"
git clone "${clone_url}" "${secrets_dir}"

log_step "Updating .sops.yaml with keys for ${host}"
cd "${secrets_dir}"
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
cd - >/dev/null

"${REPO_ROOT}/scripts/generate-secureboot-secrets.bash" "${host}" "${secrets_dir}"
"${REPO_ROOT}/scripts/generate-borgmatic-secrets.bash" "${host}" "${secrets_dir}"
"${REPO_ROOT}/scripts/generate-user-secrets.bash" "${host}" "${secrets_dir}" "${keys_dir}"

cd "${secrets_dir}"
log_step "Committing and pushing secrets repo"
git add -A
if git diff --cached --quiet; then
	echo "    No changes to secrets repo"
else
	git commit -m "feat: update keys and secrets for ${host}"
fi
git push
cd - >/dev/null

echo
log_step "Keys generated successfully"
echo "    Keys directory: ${keys_dir}"
echo "    SSH host key:   ${keys_dir}/ssh_host_ed25519_key"
echo "    User SSH key:   ${keys_dir}/id_ed25519"
echo "    User age key:   ${keys_dir}/keys.txt"
echo
echo "    Use 'just install ${host} <target> ${keys_dir}' to deploy with these keys."
echo "    Keys will be injected via --extra-files and cleaned up after deployment."
