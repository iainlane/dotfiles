#!/usr/bin/env bash

set -euo pipefail

generator="${1}"
common_library="${2}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

repo="${test_dir}/repo"
mkdir -p "${repo}/scripts/lib" "${repo}/bin" "${repo}/secrets/ancaster"
cp "${generator}" "${repo}/scripts/generate-agentsview-secrets.bash"
cp "${common_library}" "${repo}/scripts/lib/just-common.bash"

cat >"${repo}/secrets/.sops.yaml" <<'EOF'
keys:
  ancaster: &ancaster_host age1-ancaster-root
  archive: &archive_host age1-archive-root
  operator: &operator_user age1-operator
creation_rules:
  - path_regex: ^agentsview-postgres/ancaster\.yaml$
    key_groups:
      - age:
          - *archive_host
          - *operator_user
  - path_regex: ^ancaster/host-hermes\.yaml$
    key_groups:
      - age:
          - *ancaster_host
          - *operator_user
  - path_regex: ^archive/host-agentsview\.yaml$
    key_groups:
      - age:
          - *archive_host
          - *operator_user
EOF

cat >"${repo}/secrets/ancaster/host-hermes.yaml" <<'EOF'
existing_secret: keep-me
EOF

printf '#!%s\n' "${BASH}" >"${repo}/bin/nix"
cat >>"${repo}/bin/nix" <<'EOF'
set -euo pipefail

case "${*: -1}" in
*#agentsviewHosts)
	printf '%s\n' '{"ancaster":"client","bonington":"local"}'
	;;
*#agentsviewPushers)
	if [[ "${FAKE_COLLISION:-0}" == 1 ]]; then
		printf '%s\n' '{"ancaster":{"host":"ancaster","machine":"ancaster","certificate":"hosts/ancaster/agentsview.pem","passwordFile":"agentsview-postgres/ancaster.yaml","secretsFile":"ancaster/user-agentsview.yaml","recipientSource":null,"serverRecipientSource":"archive/host-agentsview.yaml"},"ancaster-hermes":{"host":"ancaster","machine":"ancaster-hermes","certificate":"hosts/ancaster/agentsview-hermes.pem","passwordFile":"agentsview-postgres/ancaster-hermes.yaml","secretsFile":"ancaster/user-agentsview.yaml","recipientSource":"ancaster/host-hermes.yaml","serverRecipientSource":"archive/host-agentsview.yaml"}}'
	else
		printf '%s\n' '{"ancaster":{"host":"ancaster","machine":"ancaster","certificate":"hosts/ancaster/agentsview.pem","passwordFile":"agentsview-postgres/ancaster.yaml","secretsFile":"ancaster/user-agentsview.yaml","recipientSource":null,"serverRecipientSource":"archive/host-agentsview.yaml"},"ancaster-hermes":{"host":"ancaster","machine":"ancaster-hermes","certificate":"hosts/ancaster/agentsview-hermes.pem","passwordFile":"agentsview-postgres/ancaster-hermes.yaml","secretsFile":"ancaster/host-hermes.yaml","recipientSource":"ancaster/host-hermes.yaml","serverRecipientSource":"archive/host-agentsview.yaml"}}'
	fi
	;;
*)
	exit 99
	;;
esac
EOF

printf '#!%s\n' "${BASH}" >"${repo}/bin/openssl"
cat >>"${repo}/bin/openssl" <<'EOF'
set -euo pipefail

if [[ "${1}" == "rand" ]]; then
	printf '%s\n' generated-value
	exit 0
fi

key_file=""
certificate=""
subject=""
while (($# > 0)); do
	case "${1}" in
	-keyout)
		key_file="${2}"
		shift 2
		;;
	-out)
		certificate="${2}"
		shift 2
		;;
	-subj)
		subject="${2}"
		shift 2
		;;
	*)
		shift
		;;
	esac
done

printf '%s\n' generated-private-key >"${key_file}"
if [[ "${FAIL_OPENSSL:-0}" == 1 ]]; then
	exit 42
fi
printf '%s\n' "${subject}" >"${certificate}"
EOF

printf '#!%s\n' "${BASH}" >"${repo}/bin/sops"
cat >>"${repo}/bin/sops" <<'EOF'
set -euo pipefail

if [[ "${1}" == "set" ]]; then
	value="$(cat)"
	path="${3}"
	key="${4#[\"}"
	key="${key%\"]}"
	SECRET_VALUE="${value}" SECRET_KEY="${key}" yq -i '.[strenv(SECRET_KEY)] = strenv(SECRET_VALUE)' "${path}"
	exit 0
fi

input="${*: -1}"
cat "${input}"
EOF

chmod +x "${repo}/bin/nix" "${repo}/bin/openssl" "${repo}/bin/sops"

run_generator() {
	TMPDIR="${repo}/tmp" PATH="${repo}/bin:${PATH}" bash "${repo}/scripts/generate-agentsview-secrets.bash" ancaster "${repo}/secrets"
}

mkdir "${repo}/tmp"
run_generator >/dev/null
[[ -z "$(find "${repo}/tmp" -mindepth 1 -print -quit)" ]]

[[ "$(cat "${repo}/hosts/ancaster/agentsview.pem")" == "/CN=ancaster" ]]
[[ "$(cat "${repo}/hosts/ancaster/agentsview-hermes.pem")" == "/CN=ancaster-hermes" ]]

yq -e '.agentsview_auth_token and .agentsview_cursor_secret and .agentsview_client_key' \
	"${repo}/secrets/ancaster/user-agentsview.yaml" >/dev/null
yq -e '.existing_secret == "keep-me" and .agentsview_client_key' \
	"${repo}/secrets/ancaster/host-hermes.yaml" >/dev/null
yq -e '.password' "${repo}/secrets/agentsview-postgres/ancaster.yaml" >/dev/null
yq -e '.password' "${repo}/secrets/agentsview-postgres/ancaster-hermes.yaml" >/dev/null

yq -e "
  .creation_rules[-1].path_regex as \$regex |
  \"agentsview-postgres/ancaster-hermes.yaml\" | test(\$regex)
" "${repo}/secrets/.sops.yaml" >/dev/null
yq -o=json '.creation_rules[-1].key_groups[0].age' "${repo}/secrets/.sops.yaml" |
	jq -e '. == ["age1-ancaster-root", "age1-operator", "age1-archive-root"]' >/dev/null

yq -i '.keys.archive = "age1-rotated-archive-root"' "${repo}/secrets/.sops.yaml"
yq -o=json '.creation_rules[-1].key_groups[0].age[2]' "${repo}/secrets/.sops.yaml" |
	jq -e '. == "age1-rotated-archive-root"' >/dev/null

before="$(find "${repo}/hosts" "${repo}/secrets" -type f -exec sha256sum {} + | sort)"
run_generator >/dev/null
after="$(find "${repo}/hosts" "${repo}/secrets" -type f -exec sha256sum {} + | sort)"
[[ "${after}" == "${before}" ]]

certificate="$(cat "${repo}/hosts/ancaster/agentsview-hermes.pem")"
rm "${repo}/hosts/ancaster/agentsview-hermes.pem"
set +e
failure="$(run_generator 2>&1)"
status=$?
set -e

[[ "${status}" -ne 0 ]]
[[ "${failure}" == *'has agentsview_client_key but '*'/agentsview-hermes.pem is missing'* ]]
printf '%s\n' "${certificate}" >"${repo}/hosts/ancaster/agentsview-hermes.pem"

set +e
failure="$(FAKE_COLLISION=1 run_generator 2>&1)"
status=$?
set -e

[[ "${status}" -ne 0 ]]
[[ "${failure}" == *'ancaster and ancaster-hermes both store agentsview_client_key in ancaster/user-agentsview.yaml'* ]]

yq -i 'del(.agentsview_client_key)' "${repo}/secrets/ancaster/host-hermes.yaml"
set +e
failure="$(run_generator 2>&1)"
status=$?
set -e

[[ "${status}" -ne 0 ]]
[[ "${failure}" == *'agentsview-hermes.pem is there but ancaster/host-hermes.yaml has no agentsview_client_key'* ]]
[[ "${failure}" != *generated-private-key* ]]

rm "${repo}/hosts/ancaster/agentsview-hermes.pem"
set +e
failure="$(FAIL_OPENSSL=1 run_generator 2>&1)"
status=$?
set -e

[[ "${status}" -eq 42 ]]
[[ "${failure}" != *generated-private-key* ]]
[[ -z "$(find "${repo}/tmp" -mindepth 1 -print -quit)" ]]
