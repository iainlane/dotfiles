#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils curl findutils gnugrep jq openssl sops yq-go
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Generate the secrets that a machine needs to back up to Cloudflare R2.
#
# Each machine gets a bucket and an account API token that reaches only that
# bucket, so a machine somebody else controls cannot read or delete another
# machine's archive:
#
#   restic-<host>                     the bucket
#   restic-<host>                     the account API token scoped to it
#   <host>/host-restic.yaml           restic_password
#                                     r2_bucket
#                                     r2_endpoint
#                                     r2_access_key_id
#                                     r2_secret_access_key
#
# The S3 credentials are derived from the token: the access key id is the
# token id and the secret access key is the SHA-256 of the token value.
# Cloudflare returns that value only when the token is created, so replacing
# the credentials means replacing the token, which `--rotate` does. Rotation
# also writes a new repository password, and the snapshots already in the
# bucket still need the previous one.
#
# The bootstrap credentials live at `cloudflare/api.yaml` in the secrets
# repository, under the keys `account_id` and `api_token`. The token has to be
# an account-owned one granting the "Account API Tokens Write" and "Workers R2
# Storage Write" permission groups, which the preflight checks before anything
# is created.
#
# The flake says which machines back up, so name a host only to limit the run
# to it. `CLOUDFLARE_API_BASE` moves the API root, which is how the script is
# exercised against a stub.
#
# Usage: generate-restic-secrets [--rotate] [host...] <secrets_dir>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

secrets_dir="${*: -1}"
arguments=("${@:1:$#-1}")

rotate=false
requested=()

for argument in "${arguments[@]}"; do
	case "${argument}" in
	--rotate)
		rotate=true
		;;

	-*)
		die "unknown option ${argument}"
		;;

	*)
		requested+=("${argument}")
		;;
	esac
done

api_base="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"

# The permission groups the bootstrap token has to grant: one to create the
# per-host tokens, one to create the buckets and reach their contents.
bootstrap_groups=(
	"Account API Tokens Write"
	"Workers R2 Storage Write"
)

# The group a per-host token grants. It is the R2 group that applies to a
# named bucket; "Workers R2 Storage Write" applies to the whole account.
bucket_group="Workers R2 Storage Bucket Item Write"

# The machines that back up to R2, one host name per line. A machine backs up
# when its resolved features include `base.restic`, which the flake works out
# from the host records.
restic_hosts() {
	nix eval --json "${REPO_ROOT}#hosts" \
		--apply 'builtins.mapAttrs (_: host: host.featureNames)' |
		jq -r 'to_entries[] | select(.value | index("base.restic")) | .key'
}

# The messages Cloudflare returned with a failed call, joined into one line.
cf_errors() {
	printf '%s' "${1}" | jq -r '[.errors[]? | "\(.code) \(.message)"] | join("; ")' 2>/dev/null
}

# Send one request to the Cloudflare API and print the response body. The
# return status follows the API's own `success` field, so a caller can handle
# an expected failure such as a bucket that is not there yet.
#
# The bearer token goes in through a curl config file, which keeps it out of
# the process list.
cf_request() {
	local method="${1}"
	local path="${2}"
	local body="${3:-}"

	local -a args=(
		--silent
		--show-error
		--config "${curl_config}"
		--request "${method}"
	)

	if [[ -n "${body}" ]]; then
		args+=(--header "Content-Type: application/json" --data "${body}")
	fi

	local response
	response="$(curl "${args[@]}" "${api_base}${path}")" ||
		die "no response from ${api_base}${path}"

	printf '%s' "${response}"

	printf '%s' "${response}" | jq -e '.success == true' >/dev/null 2>&1
}

# The id of the permission group with this name.
permission_group_id() {
	local name="${1}"

	printf '%s' "${permission_groups}" |
		jq -r --arg name "${name}" '[.result[] | select(.name == $name) | .id] | first // empty'
}

# The id of the account API token with this name, or nothing when the account
# has no token by that name.
account_token_id() {
	local name="${1}"
	local response

	response="$(cf_request GET "/accounts/${account_id}/tokens?per_page=100")" ||
		die "cannot list the account API tokens: $(cf_errors "${response}")"

	printf '%s' "${response}" |
		jq -r --arg name "${name}" '[.result[] | select(.name == $name) | .id] | first // empty'
}

ensure_bucket() {
	local bucket="${1}"
	local response

	if response="$(cf_request GET "/accounts/${account_id}/r2/buckets/${bucket}")"; then
		echo "    Bucket ${bucket} is already there"
		return 0
	fi

	response="$(cf_request POST "/accounts/${account_id}/r2/buckets" \
		"$(jq -n --arg name "${bucket}" '{name: $name}')")" ||
		die "cannot create the bucket ${bucket}: $(cf_errors "${response}")"

	echo "    Created bucket ${bucket}"
}

# Create the account API token for one bucket and print the whole response,
# which contains the token id and the token value.
create_bucket_token() {
	local name="${1}"
	local bucket="${2}"
	local response

	# A bucket resource is named by account, jurisdiction and bucket name.
	# Buckets made without a jurisdiction are in `default`.
	response="$(cf_request POST "/accounts/${account_id}/tokens" "$(jq -n \
		--arg name "${name}" \
		--arg resource "com.cloudflare.edge.r2.bucket.${account_id}_default_${bucket}" \
		--arg group "${bucket_group_id}" \
		'{
		    name: $name,
		    policies: [
		      {
		        effect: "allow",
		        resources: {($resource): "*"},
		        permission_groups: [{id: $group}]
		      }
		    ]
		  }')")" ||
		die "cannot create the API token ${name}: $(cf_errors "${response}")"

	printf '%s' "${response}"
}

delete_account_token() {
	local token_id="${1}"
	local response

	response="$(cf_request DELETE "/accounts/${account_id}/tokens/${token_id}")" ||
		die "cannot delete the API token ${token_id}: $(cf_errors "${response}")"
}

log_step "Reading the host records"
mapfile -t hosts < <(restic_hosts)

if ((${#hosts[@]} == 0)); then
	die "No host backs up to R2."
fi

# Refuse a name that matches no host: filtering by it would select no hosts,
# and the typo would go unreported.
unknown=()
for name in "${requested[@]}"; do
	printf '%s\n' "${hosts[@]}" | grep -qxF "${name}" || unknown+=("${name}")
done

if ((${#unknown[@]} > 0)); then
	die "no host that backs up to R2 is named: ${unknown[*]}"
fi

cd "${secrets_dir}"

log_step "Reading the Cloudflare bootstrap credentials"

if [[ ! -f cloudflare/api.yaml ]]; then
	die "cloudflare/api.yaml is not in the secrets repository. It contains the account id under account_id and an account-owned API token under api_token."
fi

credentials="$(sops --decrypt cloudflare/api.yaml)"
account_id="$(printf '%s' "${credentials}" | yq -r '.account_id // ""')"
api_token="$(printf '%s' "${credentials}" | yq -r '.api_token // ""')"

if [[ -z "${account_id}" || -z "${api_token}" ]]; then
	die "cloudflare/api.yaml needs both account_id and api_token"
fi

curl_config="$(make_secret_temp_file)"
printf 'header = "Authorization: Bearer %s"\n' "${api_token}" >"${curl_config}"

log_step "Checking what the bootstrap token can do"

verified="$(cf_request GET /user/tokens/verify)" ||
	die "Cloudflare rejected the bootstrap token: $(cf_errors "${verified}")"

token_status="$(printf '%s' "${verified}" | jq -r '.result.status')"
if [[ "${token_status}" != "active" ]]; then
	die "the bootstrap token is ${token_status}, not active"
fi

bootstrap_token_id="$(printf '%s' "${verified}" | jq -r '.result.id')"

bootstrap_detail="$(cf_request GET "/accounts/${account_id}/tokens/${bootstrap_token_id}")" ||
	die "cannot read the bootstrap token's own policies: $(cf_errors "${bootstrap_detail}"). It has to be an account-owned token, not a user one."

permission_groups="$(cf_request GET "/accounts/${account_id}/tokens/permission_groups?per_page=1000")" ||
	die "cannot list the account's permission groups: $(cf_errors "${permission_groups}")"

held_group_ids="$(printf '%s' "${bootstrap_detail}" |
	jq -r '[.result.policies[]?.permission_groups[]?.id] | unique | .[]')"

missing=()
for group in "${bootstrap_groups[@]}"; do
	group_id="$(permission_group_id "${group}")"

	if [[ -z "${group_id}" ]]; then
		die "Cloudflare lists no permission group named \"${group}\""
	fi

	printf '%s\n' "${held_group_ids}" | grep -qxF "${group_id}" || missing+=("${group}")
done

if ((${#missing[@]} > 0)); then
	die "the bootstrap token is missing the permission group(s): ${missing[*]}"
fi

bucket_group_id="$(permission_group_id "${bucket_group}")"

if [[ -z "${bucket_group_id}" ]]; then
	die "Cloudflare lists no permission group named \"${bucket_group}\""
fi

endpoint="https://${account_id}.r2.cloudflarestorage.com"

for host in "${hosts[@]}"; do
	if ((${#requested[@]} > 0)) && ! printf '%s\n' "${requested[@]}" | grep -qxF "${host}"; then
		continue
	fi

	bucket="restic-${host}"
	token_name="restic-${host}"
	secrets_file="${host}/host-restic.yaml"

	log_step "Generating the restic secrets for ${host}"

	existing_token_id="$(account_token_id "${token_name}")"

	if [[ -n "${existing_token_id}" && -f "${secrets_file}" && "${rotate}" == false ]]; then
		echo "    ${secrets_file} and the token ${token_name} are already there"
		continue
	fi

	ensure_bucket "${bucket}"

	if [[ -n "${existing_token_id}" ]]; then
		log_warn "${host}: replacing the token ${token_name} and the repository password. The snapshots already in the bucket still need the previous password"
		delete_account_token "${existing_token_id}"
	fi

	token="$(create_bucket_token "${token_name}" "${bucket}")"
	token_id="$(printf '%s' "${token}" | jq -r '.result.id')"
	token_value="$(printf '%s' "${token}" | jq -r '.result.value')"

	if [[ -z "${token_id}" || -z "${token_value}" || "${token_value}" == "null" ]]; then
		die "Cloudflare created ${token_name} without returning its value"
	fi

	mkdir -p "${host}"
	plaintext="$(make_secret_temp_file)"

	RESTIC_PASSWORD="$(openssl rand -hex 32)" \
	R2_BUCKET="${bucket}" \
	R2_ENDPOINT="${endpoint}" \
	R2_ACCESS_KEY_ID="${token_id}" \
	R2_SECRET_ACCESS_KEY="$(printf '%s' "${token_value}" | sha256sum | cut -d' ' -f1)" \
		yq -n '
            .restic_password = strenv(RESTIC_PASSWORD) |
            .r2_bucket = strenv(R2_BUCKET) |
            .r2_endpoint = strenv(R2_ENDPOINT) |
            .r2_access_key_id = strenv(R2_ACCESS_KEY_ID) |
            .r2_secret_access_key = strenv(R2_SECRET_ACCESS_KEY)
        ' >"${plaintext}"

	encrypt_yaml_file "${plaintext}" "${secrets_file}"
	echo "    Wrote ${secrets_file}"
done
