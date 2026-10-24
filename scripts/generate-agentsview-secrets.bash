#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils findutils gnugrep jq openssl sops yq-go
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Generate the secrets that a machine needs for AgentsView.
#
# Every machine that keeps an archive of its agent sessions needs two values
# that AgentsView generates for itself when its configuration is writable.
# Nix renders the configuration read-only, so both come from here:
#
#   <host>/user-agentsview.yaml       agentsview_auth_token
#                                     agentsview_cursor_secret
#
# An archive identity that also pushes to the shared database needs a password,
# a certificate, and the key of that certificate:
#
#   agentsview-postgres/<machine>.yaml password
#   <configured secrets file>          agentsview_client_key
#   hosts/<host>/<certificate>.pem     the certificate that the proxy checks
#
# The machine that runs the database and serves the dashboard needs four more:
#
#   <host>/host-agentsview.yaml       agentsview_superuser_password
#                                     agentsview_dashboard_password
#                                     agentsview_auth_token
#                                     agentsview_cursor_secret
#
# The flake says which machines these are, so name a host only to limit the
# run to it. This script generates each value that a host does not have yet
# and leaves the others alone.
#
# Creating a new file needs only the public keys, so it works for any host.
# Adding a key to a file that is already there means sops decrypts it first,
# so run the script on a machine that the rule in `.sops.yaml` covers. Listing
# the keys in a file needs no decryption: sops encrypts the values and leaves
# the keys in plain text.
#
# Usage: generate-agentsview-secrets --repo-root <dotfiles_dir> [host...] <secrets_dir>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "${AGENTSVIEW_COMMON_LIBRARY:-$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash}"

if [[ "${1:-}" == --help ]]; then
	echo "usage: generate-agentsview-secrets --repo-root <dotfiles_dir> [host...] <secrets_dir>"
	exit 0
fi

if [[ "${1:-}" != --repo-root || "$#" -lt 3 ]]; then
	die "usage: generate-agentsview-secrets --repo-root <dotfiles_dir> [host...] <secrets_dir>"
fi
repo_root="$(cd "${2}" && pwd)"
shift 2
plan="${AGENTSVIEW_PROVISIONING_PLAN:?The provisioner must supply its credential plan}"

secrets_dir="${*: -1}"
requested=("${@:1:$#-1}")

# Whether an encrypted file already has a key. sops encrypts the values and
# leaves the keys in plain text, so this reads the file without decrypting it.
has_secret() {
	local path="${1}"
	local key="${2}"

	[[ -f "${path}" ]] && yq -e 'has("'"${key}"'")' "${path}" >/dev/null 2>&1
}

# Add one key to a file that is already encrypted. sops reads the value from
# stdin, so the value stays out of the process list.
add_secret() {
	local path="${1}"
	local key="${2}"

	SECRET_VALUE="${3}" yq -n -o=json 'strenv(SECRET_VALUE)' |
		sops set --value-stdin "${path}" "[\"${key}\"]"

	echo "    ${path}: added ${key}"
}

agentsview_hosts() {
	jq -r '.hosts | keys[]' "${plan}"
}

agentsview_pushers() {
	jq -r '.hosts | to_entries[] | .key as $host | .value.publishers[] | [$host, .machine, .certificate, .passwordFile, .secretsFile, .recipientSource, .serverRecipientSource] | @tsv' "${plan}"
}

creation_rule_for() {
	SOURCE_PATH="${1}" yq -o=json "
        .creation_rules |
        map(select(.path_regex as \$regex | strenv(SOURCE_PATH) | test(\$regex))) | .[0]
    " .sops.yaml
}

age_recipients_for() {
	local path="${1}"
	creation_rule_for "${path}" | jq -ce '
        select((.key_groups | length) == 1 and
               (.key_groups[0] | keys) == ["age"] and
               (.key_groups[0].age | length) > 0) |
        .key_groups[0].age
    ' || die "No single age key group covers ${path}."
}

check_password_recipients() {
	local password_file="${1}"
	local expected="${2}"

	if [[ ! -f "${password_file}" ]]; then
		return 0
	fi

	yq -o=json '.sops' "${password_file}" | jq -e --argjson expected "${expected}" '
        def age_only:
            all(.pgp, .kms, .gcp_kms, .hckms, .azure_kv, .hc_vault; (. // [] | length) == 0);
        (.key_groups // []) as $groups |
        (.shamir_threshold // 1) <= 1 and
        age_only and all($groups[]; age_only) and
        (if ($groups | length) == 0 then
            ([.age[]?.recipient] | unique) == ($expected | unique)
         elif ($groups | length) == 1 and ((.age // []) | length) == 0 then
            ([$groups[0].age[]?.recipient] | unique) == ($expected | unique)
         else false end)
    ' >/dev/null || die "${password_file} has stale encrypted recipients; run sops updatekeys on this file before provisioning."
}

# The rule that lets the server and the machine itself read the password.
add_password_rule() {
	local password_file="${1}"
	local recipient_source="${2}"
	local server_recipient_source="${3}"
	local client_recipients server_recipients required rule

	client_recipients="$(age_recipients_for "${recipient_source}")"
	server_recipients="$(age_recipients_for "${server_recipient_source}")"
	required="$(jq -cn --argjson client "${client_recipients}" --argjson server "${server_recipients}" '$client + $server | unique')"
	rule="$(creation_rule_for "${password_file}")"

	if [[ "${rule}" != null ]]; then
		jq -e --argjson required "${required}" '
            (.key_groups | length) == 1 and
            (.key_groups[0] | keys) == ["age"] and
            ($required - .key_groups[0].age | length) == 0
        ' <<<"${rule}" >/dev/null || die "The first creation rule for ${password_file} must include the client and server age recipients."
		check_password_recipients "${password_file}" "$(jq -c '.key_groups[0].age' <<<"${rule}")"
		echo "    .sops.yaml already covers ${password_file}"
		return 0
	fi

	local password_regex
	password_regex="$(jq -nr --arg path "${password_file}" '$path | "^" + gsub("(?<character>[.^$*+?()\\[\\]{}|\\\\])"; "\\\(.character)") + "$"')"
	PASSWORD_REGEX="${password_regex}" SOURCE_PATH="${recipient_source}" SERVER_PATH="${server_recipient_source}" yq -i "
	    (.creation_rules | map(select(.path_regex as \$regex | strenv(SOURCE_PATH) | test(\$regex))) | .[0].key_groups[0].age) as \$client |
	    (.creation_rules | map(select(.path_regex as \$regex | strenv(SERVER_PATH) | test(\$regex))) | .[0].key_groups[0].age) as \$server |
	    .creation_rules += [{
	        \"path_regex\": strenv(PASSWORD_REGEX),
	        \"key_groups\": [{\"age\": ((\$client + \$server) | unique)}]
	    }]
	" .sops.yaml
	check_password_recipients "${password_file}" "${required}"
	echo "    Added a rule for ${password_file}"
}

# The auth token and the cursor secret every machine needs, and for a machine
# that pushes, the key of its certificate as well.
#
# Creating the file needs only the recipients' public keys. A certificate
# re-issued later has its new key added to the file that already exists, and
# updating an encrypted file means decrypting it first, so run the script on a
# machine that a rule in `.sops.yaml` covers.
generate_user_secrets() {
	local user_file="${1}"
	local client_key="${2:-}"
	local plaintext key

	mkdir -p "$(dirname "${user_file}")"

	if [[ -f "${user_file}" ]]; then
		for key in agentsview_auth_token agentsview_cursor_secret; do
			if has_secret "${user_file}" "${key}"; then
				echo "    ${user_file}: ${key} is already set"
				continue
			fi

			add_secret "${user_file}" "${key}" "$(openssl rand -base64 32)"
		done

		if [[ -n "${client_key}" ]]; then
			add_secret "${user_file}" "agentsview_client_key" "${client_key}"
		fi

		return 0
	fi

	make_secret_temp_file plaintext
	AUTH_TOKEN="$(openssl rand -base64 32)" \
	CURSOR_SECRET="$(openssl rand -base64 32)" \
		yq -n '
            .agentsview_auth_token = strenv(AUTH_TOKEN) |
            .agentsview_cursor_secret = strenv(CURSOR_SECRET)
        ' >"${plaintext}"

	if [[ -n "${client_key}" ]]; then
		CLIENT_KEY="${client_key}" \
			yq -i '.agentsview_client_key = strenv(CLIENT_KEY)' "${plaintext}"
	fi

	encrypt_yaml_file "${plaintext}" "${user_file}"
	echo "    Created ${user_file}"
}

check_client_key_pair() {
	local certificate="${1}"
	local secrets_file="${2}"
	local client_private_key certificate_public_key client_public_key

	make_secret_temp_file client_private_key
	make_secret_temp_file certificate_public_key
	make_secret_temp_file client_public_key

	if ! sops decrypt --extract '["agentsview_client_key"]' "${secrets_file}" >"${client_private_key}"; then
		die "${secrets_file} has agentsview_client_key but it could not be decrypted. Run this on a machine that the .sops.yaml rule for ${secrets_file} covers."
	fi

	if ! openssl x509 -in "${certificate}" -pubkey -noout -out "${certificate_public_key}"; then
		die "${certificate} is not a readable certificate. Restore a readable certificate that matches the stored key, then run this again."
	fi

	if ! openssl pkey -in "${client_private_key}" -passin pass: -pubout -out "${client_public_key}"; then
		die "${secrets_file} does not contain a usable agentsview_client_key. Restore a usable key that matches ${certificate}, then run this again."
	fi

	if ! cmp -s "${certificate_public_key}" "${client_public_key}"; then
		die "${certificate} does not match agentsview_client_key in ${secrets_file}. Restore a matching certificate and private key before running again. Remove both only if you intend to generate a new pair."
	fi
}

check_client_identity() {
	local certificate="${1}"
	local secrets_file="${2}"

	if [[ ! -f "${certificate}" ]]; then
		if has_secret "${secrets_file}" "agentsview_client_key"; then
			die "${secrets_file} has agentsview_client_key but ${certificate} is missing. Restore the matching certificate or remove the key before generating a new pair."
		fi
		return
	fi
	if ! has_secret "${secrets_file}" "agentsview_client_key"; then
		die "${certificate} is there but ${secrets_file} has no agentsview_client_key. Restore the matching key or remove the certificate before generating a new pair."
	fi
	check_client_key_pair "${certificate}" "${secrets_file}"
}

generate_client_secrets() {
	local machine="${1}"
	local certificate="${repo_root}/${2}"
	local password_file="${3}"
	local secrets_file="${4}"
	local recipient_source="${5}"
	local server_recipient_source="${6}"

	local client_key=""
	local key_file plaintext

	add_password_rule "${password_file}" "${recipient_source}" "${server_recipient_source}"

	mkdir -p "$(dirname "${password_file}")"

	if [[ -f "${certificate}" ]]; then
		echo "    ${certificate} is already there"
	else
		make_secret_temp_file key_file
		mkdir -p "$(dirname "${certificate}")"

		# By default, openssl writes the full curve parameters. Go rejects a
		# key of that form, so the command asks for the named-curve encoding.
		openssl req -x509 -newkey ec \
			-pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve \
			-nodes -days 36500 -subj "/CN=${machine}" \
			-keyout "${key_file}" \
			-out "${certificate}"

		client_key="$(cat "${key_file}")"
		log_note "Commit ${certificate} in the dotfiles repository."
	fi

	# A password goes into a connection URL, where `/`, `#`, `?` and `:` read
	# as a port or a path. Hex avoids them all.
	if has_secret "${password_file}" "password"; then
		echo "    ${password_file}: password is already set"
	elif [[ -f "${password_file}" ]]; then
		add_secret "${password_file}" "password" "$(openssl rand -hex 32)"
	else
		make_secret_temp_file plaintext
		PASSWORD="$(openssl rand -hex 32)" yq -n '.password = strenv(PASSWORD)' >"${plaintext}"
		encrypt_yaml_file "${plaintext}" "${password_file}"
		echo "    Created ${password_file}"
	fi

	if [[ -n "${client_key}" ]]; then
		if [[ -f "${secrets_file}" ]]; then
			add_secret "${secrets_file}" "agentsview_client_key" "${client_key}"
		else
			plaintext=""
			make_secret_temp_file plaintext
			CLIENT_KEY="${client_key}" yq -n '.agentsview_client_key = strenv(CLIENT_KEY)' >"${plaintext}"
			mkdir -p "$(dirname "${secrets_file}")"
			encrypt_yaml_file "${plaintext}" "${secrets_file}"
			echo "    Created ${secrets_file}"
		fi
	fi
}

generate_server_secrets() {
	local server_file="${1}"

	local plaintext key

	# The dashboard's password is inserted into a connection URL, where the
	# characters `/`, `#`, `?` and `:` are reserved. Hex avoids all of them, and
	# the superuser password is generated the same way.
	local -A secrets=(
		[agentsview_superuser_password]="$(openssl rand -hex 32)"
		[agentsview_dashboard_password]="$(openssl rand -hex 32)"
		[agentsview_auth_token]="$(openssl rand -base64 32)"
		[agentsview_cursor_secret]="$(openssl rand -base64 32)"
	)

	if [[ -f "${server_file}" ]]; then
		for key in "${!secrets[@]}"; do
			if has_secret "${server_file}" "${key}"; then
				echo "    ${server_file}: ${key} is already set"
				continue
			fi

			add_secret "${server_file}" "${key}" "${secrets[${key}]}"
		done

		return 0
	fi

	mkdir -p "$(dirname "${server_file}")"
	make_secret_temp_file plaintext
	: >"${plaintext}"

	for key in "${!secrets[@]}"; do
		SECRET_KEY="${key}" SECRET_VALUE="${secrets[${key}]}" \
			yq -i '.[strenv(SECRET_KEY)] = strenv(SECRET_VALUE)' "${plaintext}"
	done

	encrypt_yaml_file "${plaintext}" "${server_file}"
	echo "    Created ${server_file}"
}

log_step "Reading the host records"
hosts_output="$(agentsview_hosts)" || die "Could not read the AgentsView hosts."
pushers_output="$(agentsview_pushers)" || die "Could not read the AgentsView publishers."
if [[ -z "${hosts_output}" ]]; then
	die "The AgentsView provisioning plan has no hosts."
fi

mapfile -t hosts <<<"${hosts_output}"
pushers=()
if [[ -n "${pushers_output}" ]]; then
	mapfile -t pushers <<<"${pushers_output}"
fi

declare -A key_owners=()
for pusher in "${pushers[@]}"; do
	IFS=$'\t' read -r _ machine _ _ secrets_file _ <<<"${pusher}"

	if [[ -n "${key_owners[${secrets_file}]:-}" ]]; then
		die "AgentsView pushers ${key_owners[${secrets_file}]} and ${machine} both store agentsview_client_key in ${secrets_file}. Configure separate secrets files."
	fi

	key_owners["${secrets_file}"]="${machine}"
done

# Refuse a name that matches no host: filtering by it would select no hosts,
# and the typo would go unreported.
if ((${#requested[@]} > 0)); then
	known=("${hosts[@]}")

	unknown=()
	for name in "${requested[@]}"; do
		printf '%s\n' "${known[@]}" | grep -qxF "${name}" || unknown+=("${name}")
	done

	if ((${#unknown[@]} > 0)); then
		die "no host with the agentsview feature is named: ${unknown[*]}"
	fi
fi

cd "${secrets_dir}"

for pusher in "${pushers[@]}"; do
	IFS=$'\t' read -r pusher_host machine certificate password_file secrets_file recipient_source server_recipient_source <<<"${pusher}"
	if ((${#requested[@]} > 0)) && ! printf '%s\n' "${requested[@]}" | grep -qxF "${pusher_host}"; then
		continue
	fi
	check_client_identity "${repo_root}/${certificate}" "${secrets_file}"
done

generate_pusher() {
	local wanted_machine="${1}"
	local pusher

	for pusher in "${pushers[@]}"; do
		IFS=$'\t' read -r pusher_host machine certificate password_file secrets_file recipient_source server_recipient_source <<<"${pusher}"
		if [[ "${machine}" != "${wanted_machine}" ]]; then
			continue
		fi

		generate_client_secrets \
			"${machine}" \
			"${certificate}" \
			"${password_file}" \
			"${secrets_file}" \
			"${recipient_source}" \
			"${server_recipient_source}"
		return 0
	done

	die "The AgentsView provisioning plan has no publisher named ${wanted_machine}."
}

for host in "${hosts[@]}"; do
	if ((${#requested[@]} > 0)) && ! printf '%s\n' "${requested[@]}" | grep -qxF "${host}"; then
		continue
	fi

	log_step "Generating the AgentsView secrets for ${host}"
	user_file="$(jq -r --arg host "${host}" '.hosts[$host].userSecretsFile // empty' "${plan}")"
	server_file="$(jq -r --arg host "${host}" '.hosts[$host].serverSecretsFile // empty' "${plan}")"
	if [[ -n "${user_file}" ]]; then
		generate_user_secrets "${user_file}"
	fi
	if [[ -n "${server_file}" ]]; then
		generate_server_secrets "${server_file}"
	fi

	for pusher in "${pushers[@]}"; do
		IFS=$'\t' read -r pusher_host machine _ <<<"${pusher}"
		if [[ "${pusher_host}" == "${host}" ]]; then
			generate_pusher "${machine}"
		fi
	done
done
