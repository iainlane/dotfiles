#!/usr/bin/env bash

set -euo pipefail

generator="${1}"
common_library="${2}"
real_openssl="${3}"
real_sops="${4}"
real_age_keygen="${5}"
system_path="${PATH}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

repo="${test_dir}/repo"
editable_repo="${test_dir}/editable"
mkdir "${editable_repo}"
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
          - *ancaster_host
          - *operator_user
          - age1-auditor
  - path_regex: ^ancaster/user-agentsview\.yaml$
    key_groups:
      - age:
          - *ancaster_host
          - *operator_user
  - path_regex: ^ancaster/host-hermes\.yaml$
    key_groups:
      - age:
          - *ancaster_host
          - *operator_user
  - path_regex: ^archive/custom-server\.yaml$
    key_groups:
      - age:
          - *archive_host
          - *operator_user
EOF

cat >"${repo}/secrets/ancaster/host-hermes.yaml" <<'EOF'
existing_secret: keep-me
EOF

cat >"${repo}/plan.json" <<'EOF'
{"hosts":{"ancaster":{"userSecretsFile":"ancaster/user-agentsview.yaml","serverSecretsFile":null,"publishers":{"ancaster":{"machine":"ancaster","certificate":"hosts/ancaster/agentsview.pem","passwordFile":"agentsview-postgres/ancaster.yaml","secretsFile":"ancaster/user-agentsview.yaml","recipientSource":"ancaster/user-agentsview.yaml","serverRecipientSource":"archive/custom-server.yaml"},"ancaster-hermes":{"machine":"ancaster-hermes","certificate":"hosts/ancaster/agentsview-hermes.pem","passwordFile":"custom-passwords/ancaster-hermes+postgres.yaml","secretsFile":"ancaster/host-hermes.yaml","recipientSource":"ancaster/host-hermes.yaml","serverRecipientSource":"archive/custom-server.yaml"}}},"bonington":{"userSecretsFile":"bonington/local.yaml","serverSecretsFile":null,"publishers":{}},"archive":{"userSecretsFile":null,"serverSecretsFile":"archive/custom-server.yaml","publishers":{}}}}
EOF
printf '#!%s\nexit 99\n' "${BASH}" >"${repo}/bin/nix"

printf '#!%s\n' "${BASH}" >"${repo}/bin/openssl"
cat >>"${repo}/bin/openssl" <<'EOF'
set -euo pipefail

if [[ "${1}" == "rand" ]]; then
	printf '%s\n' generated-value
	exit 0
fi

if [[ "${1}" == "pkey" ]]; then
	key_file=""
	output=""
	while (($# > 0)); do
		case "${1}" in
		-in)
			key_file="${2}"
			shift 2
			;;
		-out)
			output="${2}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	printf 'pub:%s\n' "$(cat "${key_file}")" >"${output}"
	exit 0
fi

if [[ "${1}" == "x509" ]]; then
	output=""
	while (($# > 0)); do
		case "${1}" in
		-out)
			output="${2}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	printf '%s\n' pub:generated-private-key >"${output}"
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
	value="$(jq -r '.' <<<"$(cat)")"
	path="${3}"
	key="${4#[\"}"
	key="${key%\"]}"
	SECRET_VALUE="${value}" SECRET_KEY="${key}" yq -i '.[strenv(SECRET_KEY)] = strenv(SECRET_VALUE)' "${path}"
	exit 0
fi

if [[ "${1}" == "decrypt" ]]; then
	extract=""
	path=""
	while (($# > 0)); do
		case "${1}" in
		--extract)
			extract="${2}"
			shift 2
			;;
		*)
			path="${1}"
			shift
			;;
		esac
	done
	key="$(jq -r '.[0]' <<<"${extract}")"
	yq -r ".${key}" "${path}"
	exit 0
fi

input="${*: -1}"
filename=""
while (($# > 0)); do
  if [[ "${1}" == --filename-override ]]; then
    filename="${2}"
    break
  fi
  shift
done
recipients="$(SOPS_FILENAME="${filename}" yq -o=json '.creation_rules | map(select(.path_regex as $regex | strenv(SOPS_FILENAME) | test($regex))) | .[0].key_groups[0].age' .sops.yaml)"
SOPS_RECIPIENTS="${recipients}" yq '.sops.age = (strenv(SOPS_RECIPIENTS) | from_json | map({"recipient": .}))' "${input}"
EOF

chmod +x "${repo}/bin/nix" "${repo}/bin/openssl" "${repo}/bin/sops"

run_generator() {
	jq 'if env.FAKE_COLLISION == "1" then .hosts.ancaster.publishers["ancaster-hermes"].secretsFile = "ancaster/user-agentsview.yaml" else . end' "${repo}/plan.json" >"${repo}/active-plan.json"
	AGENTSVIEW_PROVISIONING_PLAN="${repo}/active-plan.json" TMPDIR="${repo}/tmp" PATH="${repo}/bin:${PATH}" bash "${repo}/scripts/generate-agentsview-secrets.bash" --repo-root "${editable_repo}" ancaster "${repo}/secrets"
}

mkdir "${repo}/tmp"
run_generator >/dev/null
[[ -z "$(find "${repo}/tmp" -mindepth 1 -print -quit)" ]]

[[ "$(cat "${editable_repo}/hosts/ancaster/agentsview.pem")" == "/CN=ancaster" ]]
[[ "$(cat "${editable_repo}/hosts/ancaster/agentsview-hermes.pem")" == "/CN=ancaster-hermes" ]]

yq -e '.agentsview_auth_token and .agentsview_cursor_secret and .agentsview_client_key' \
	"${repo}/secrets/ancaster/user-agentsview.yaml" >/dev/null
yq -e '.existing_secret == "keep-me" and .agentsview_client_key' \
	"${repo}/secrets/ancaster/host-hermes.yaml" >/dev/null
yq -e '.password' "${repo}/secrets/agentsview-postgres/ancaster.yaml" >/dev/null
yq -e '.password' "${repo}/secrets/custom-passwords/ancaster-hermes+postgres.yaml" >/dev/null

yq -e "
  .creation_rules[-1].path_regex as \$regex |
  \"custom-passwords/ancaster-hermes+postgres.yaml\" | test(\$regex)
" "${repo}/secrets/.sops.yaml" >/dev/null
yq -o=json '.creation_rules[-1].key_groups[0].age' "${repo}/secrets/.sops.yaml" |
	jq -e '. == ["age1-ancaster-root", "age1-operator", "age1-archive-root"]' >/dev/null

run_generator >/dev/null
password_file="${repo}/secrets/agentsview-postgres/ancaster.yaml"
metadata="$(yq -o=json '.sops' "${password_file}")"
for mutation in \
	'.pgp = [{"fp": "revoked", "enc": "fixture"}]' \
	'.key_groups = [{"age": .age, "kms": [{"arn": "revoked", "enc": "fixture"}]}] | del(.age)' \
	'.key_groups = [{"age": [.age[-1]]}] | .age = .age[:-1]'; do
	SOPS_METADATA="$(jq -c "${mutation}" <<<"${metadata}")" yq -i '.sops = (strenv(SOPS_METADATA) | from_json)' "${password_file}"
	set +e
	failure="$(run_generator 2>&1)"
	status=$?
	set -e
	[[ "${status}" -ne 0 ]] || {
		echo "Expected unsupported recipient metadata to fail: ${mutation}" >&2
		exit 1
	}
	[[ "${failure}" == *"encrypted recipients"* ]]
done
for mutation in \
	'. + {"pgp": [], "kms": [], "gcp_kms": [], "hckms": [], "azure_kv": [], "hc_vault": [], "key_groups": []}' \
	'{"age": [], "pgp": [], "kms": [], "gcp_kms": [], "hckms": [], "azure_kv": [], "hc_vault": [], "key_groups": [. + {"pgp": [], "kms": [], "gcp_kms": [], "hckms": [], "azure_kv": [], "hc_vault": []}]}'; do
	SOPS_METADATA="$(jq -c "${mutation}" <<<"${metadata}")" yq -i '.sops = (strenv(SOPS_METADATA) | from_json)' "${password_file}"
	run_generator >/dev/null
done
SOPS_METADATA="${metadata}" yq -i '.sops = (strenv(SOPS_METADATA) | from_json)' "${password_file}"

yq -i 'del(.creation_rules[0].key_groups[0].age[] | select(. == "age1-auditor"))' "${repo}/secrets/.sops.yaml"
set +e
failure="$(run_generator 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || {
	echo "Expected revoked encrypted recipients to fail" >&2
	exit 1
}
[[ "${failure}" == *"encrypted recipients"* ]]
yq -i 'del(.sops.age[] | select(.recipient == "age1-auditor"))' "${repo}/secrets/agentsview-postgres/ancaster.yaml"

yq -i '.keys.archive = "age1-rotated-archive-root"' "${repo}/secrets/.sops.yaml"
yq -o=json '.creation_rules[-1].key_groups[0].age[2]' "${repo}/secrets/.sops.yaml" |
	jq -e '. == "age1-rotated-archive-root"' >/dev/null

set +e
failure="$(run_generator 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || {
	echo "Expected stale encrypted recipients to fail" >&2
	exit 1
}
[[ "${failure}" == *"encrypted recipients"* ]]
for file in "${repo}/secrets/agentsview-postgres/ancaster.yaml" "${repo}/secrets/custom-passwords/ancaster-hermes+postgres.yaml"; do
	yq -i '(.sops.age[] | select(.recipient == "age1-archive-root")).recipient = "age1-rotated-archive-root"' "${file}"
done

before="$(find "${editable_repo}/hosts" "${repo}/secrets" -type f -exec sha256sum {} + | sort)"
run_generator >/dev/null
after="$(find "${editable_repo}/hosts" "${repo}/secrets" -type f -exec sha256sum {} + | sort)"
[[ "${after}" == "${before}" ]]

certificate="$(cat "${editable_repo}/hosts/ancaster/agentsview-hermes.pem")"
rm "${editable_repo}/hosts/ancaster/agentsview-hermes.pem"
set +e
failure="$(run_generator 2>&1)"
status=$?
set -e

[[ "${status}" -ne 0 ]]
[[ "${failure}" == *'has agentsview_client_key but '*'/agentsview-hermes.pem is missing'* ]]
printf '%s\n' "${certificate}" >"${editable_repo}/hosts/ancaster/agentsview-hermes.pem"

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

rm "${editable_repo}/hosts/ancaster/agentsview-hermes.pem"
set +e
failure="$(FAIL_OPENSSL=1 run_generator 2>&1)"
status=$?
set -e

[[ "${status}" -eq 42 ]]
[[ "${failure}" != *generated-private-key* ]]
[[ -z "$(find "${repo}/tmp" -mindepth 1 -print -quit)" ]]

AGENTSVIEW_PROVISIONING_PLAN="${repo}/plan.json" PATH="${repo}/bin:${PATH}" bash "${repo}/scripts/generate-agentsview-secrets.bash" --repo-root "${editable_repo}" archive bonington "${repo}/secrets" >/dev/null
yq -e '.agentsview_superuser_password and .agentsview_dashboard_password and .agentsview_auth_token and .agentsview_cursor_secret' "${repo}/secrets/archive/custom-server.yaml" >/dev/null
yq -e '.agentsview_auth_token and .agentsview_cursor_secret' "${repo}/secrets/bonington/local.yaml" >/dev/null
[[ ! -e "${repo}/secrets/archive/host-agentsview.yaml" ]]
[[ ! -e "${editable_repo}/hosts/bonington/agentsview.pem" ]]

set +e
failure="$(AGENTSVIEW_PROVISIONING_PLAN="${repo}/plan.json" PATH="${repo}/bin:${PATH}" bash "${repo}/scripts/generate-agentsview-secrets.bash" --repo-root "${editable_repo}" unknown "${repo}/secrets" 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]]
[[ "${failure}" == *"unknown"* ]]
[[ ! -e "${repo}/hosts" ]]

jq '.hosts.ancaster.publishers.ancaster.passwordFile = "blocked/new.yaml"' "${repo}/plan.json" >"${repo}/blocked-plan.json"
yq -i '.creation_rules = [{"path_regex": "^blocked/", "key_groups": [{"age": ["age1-operator", "age1-rotated-archive-root"]}]}, {"path_regex": "^blocked/new[.]yaml$", "key_groups": [{"age": ["age1-ancaster-root", "age1-operator", "age1-rotated-archive-root"]}]}] + .creation_rules' "${repo}/secrets/.sops.yaml"
set +e
failure="$(AGENTSVIEW_PROVISIONING_PLAN="${repo}/blocked-plan.json" TMPDIR="${repo}/tmp" PATH="${repo}/bin:${PATH}" bash "${repo}/scripts/generate-agentsview-secrets.bash" --repo-root "${editable_repo}" ancaster "${repo}/secrets" 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]]
[[ "${failure}" == *"first creation rule"* ]]
[[ ! -e "${repo}/secrets/blocked/new.yaml" ]]

real_bin="${test_dir}/real-bin"
real_repo="${test_dir}/real-repo"
real_editable="${test_dir}/real-editable"
real_secrets="${real_repo}/secrets"
age_key="${test_dir}/age-key.txt"
mkdir -p "${real_bin}" "${real_editable}" "${real_secrets}/fixture" "${real_repo}/scripts/lib" "${real_editable}/hosts/fixture"
ln -s "${real_openssl}" "${real_bin}/openssl"
ln -s "${real_sops}" "${real_bin}/sops"
ln -s "${real_age_keygen}" "${real_bin}/age-keygen"
cp "${generator}" "${real_repo}/scripts/generate-agentsview-secrets.bash"
cp "${common_library}" "${real_repo}/scripts/lib/just-common.bash"

"${real_age_keygen}" -o "${age_key}" >/dev/null
recipient="$("${real_age_keygen}" -y "${age_key}")"

cat >"${real_secrets}/.sops.yaml" <<SOPS_CONFIG_EOF
creation_rules:
  - path_regex: ^fixture/user-agentsview\\.yaml$
    key_groups:
      - age:
          - ${recipient}
  - path_regex: ^fixture/new-user\\.yaml$
    key_groups:
      - age:
          - ${recipient}
  - path_regex: ^fixture/server\\.yaml$
    key_groups:
      - age:
          - ${recipient}
SOPS_CONFIG_EOF

make_key_pair() {
	local subject="${1}"
	local key_file="${2}"
	local certificate="${3}"

	"${real_openssl}" req -x509 -newkey ec \
		-pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve \
		-nodes -days 36500 -subj "/CN=${subject}" \
		-keyout "${key_file}" \
		-out "${certificate}" >/dev/null 2>&1
}

make_key_pair fixture-a "${test_dir}/key-a.pem" "${test_dir}/cert-a.pem"
make_key_pair fixture-b "${test_dir}/key-b.pem" "${test_dir}/cert-b.pem"

CLIENT_KEY="$(cat "${test_dir}/key-a.pem")" \
	yq -n '.agentsview_client_key = strenv(CLIENT_KEY)' >"${test_dir}/client-plaintext.yaml"
(
	cd "${real_secrets}"
	SOPS_AGE_KEY_FILE="${age_key}" "${real_sops}" --encrypt \
		--input-type yaml --output-type yaml \
		--filename-override "fixture/user-agentsview.yaml" \
		"${test_dir}/client-plaintext.yaml" >"${test_dir}/client-encrypted.yaml"
	mv "${test_dir}/client-encrypted.yaml" fixture/user-agentsview.yaml
)
cp "${test_dir}/cert-b.pem" "${real_editable}/hosts/fixture/agentsview.pem"

cat >"${real_repo}/plan.json" <<'PLAN_EOF'
{"hosts":{"fixture":{"userSecretsFile":"fixture/new-user.yaml","serverSecretsFile":"fixture/server.yaml","publishers":{"fixture":{"machine":"fixture","certificate":"hosts/fixture/agentsview.pem","passwordFile":"agentsview-postgres/fixture.yaml","secretsFile":"fixture/user-agentsview.yaml","recipientSource":"fixture/user-agentsview.yaml","serverRecipientSource":"fixture/server.yaml"}}}}}
PLAN_EOF

run_real_generator() {
	AGENTSVIEW_PROVISIONING_PLAN="${real_repo}/plan.json" \
		SOPS_AGE_KEY_FILE="${age_key}" \
		PATH="${real_bin}:${system_path}" \
		bash "${real_repo}/scripts/generate-agentsview-secrets.bash" \
		--repo-root "${real_editable}" fixture "${real_secrets}"
}

real_snapshot() {
	find "${real_editable}" "${real_secrets}" -type f -exec sha256sum {} + | sort
}

before="$(real_snapshot)"
set +e
failure="$(run_real_generator 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || {
	echo "Expected a certificate that does not match the stored key to fail" >&2
	exit 1
}
[[ "${failure}" == *"does not match agentsview_client_key"* ]]
[[ "${failure}" != *"PRIVATE KEY"* ]]
[[ "$(real_snapshot)" == "${before}" ]] || {
	echo "A mismatched client key changed the secrets repository" >&2
	exit 1
}

cp "${test_dir}/cert-a.pem" "${real_editable}/hosts/fixture/agentsview.pem"
run_real_generator >/dev/null
[[ "$(cd "${real_secrets}" && SOPS_AGE_KEY_FILE="${age_key}" "${real_sops}" decrypt --extract '["agentsview_client_key"]' fixture/user-agentsview.yaml)" == "$(cat "${test_dir}/key-a.pem")" ]]
before="$(real_snapshot)"
run_real_generator >/dev/null
[[ "$(real_snapshot)" == "${before}" ]]

printf 'Publisher certificate and client key pairing checks passed.\n'
