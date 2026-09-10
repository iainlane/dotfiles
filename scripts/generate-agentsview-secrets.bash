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
# Usage: generate-agentsview-secrets [host...] <secrets_dir>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

secrets_dir="${*: -1}"
requested=("${@:1:$#-1}")

# The server reads every machine's password to keep the database roles in step,
# so the password file is encrypted to the server's host key as well as to the
# machine's own user key. The user file needs no rule of its own, because
# `^<host>/user-.*\.yaml$` covers it.
server_anchor="ancaster_host"

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

# The machines that need AgentsView secrets, one `<kind> <host>` line each.
# The flake works this out from the host records.
agentsview_hosts() {
	nix eval --json "${REPO_ROOT}#agentsviewHosts" |
		jq -r 'to_entries[] | "\(.value) \(.key)"'
}

# The identities that push to the shared archive. This includes additional
# identities supplied by host features, with paths taken from their evaluated
# configuration.
agentsview_pushers() {
	nix eval --json "${REPO_ROOT}#agentsviewPushers" |
		jq -r 'to_entries[] | [.value.host, .value.machine, .value.certificate, .value.passwordFile, .value.secretsFile, (.value.recipientSource // "-"), .value.serverRecipientSource] | @tsv'
}

# The rule that lets the server and the machine itself read the password.
add_password_rule() {
	local machine="${1}"
	local host="${2}"
	local recipient_source="${3:-}"
	local server_recipient_source="${4}"

	if PASSWORD_PATH="agentsview-postgres/${machine}.yaml" yq -e ".creation_rules[] | select(.path_regex as \$regex | strenv(PASSWORD_PATH) | test(\$regex))" .sops.yaml >/dev/null 2>&1; then
		echo "    .sops.yaml already covers ${machine}"
		return 0
	fi

	if [[ -n "${recipient_source}" ]]; then
		local source
		for source in "${recipient_source}" "${server_recipient_source}"; do
			SOURCE_PATH="${source}" yq -o=json "
			    .creation_rules |
			    map(select(.path_regex as \$regex | strenv(SOURCE_PATH) | test(\$regex))) | .[0]
			" .sops.yaml | jq -e '
			    (.key_groups | length) == 1 and
			    (.key_groups[0] | keys) == ["age"] and
			    (.key_groups[0].age | length) > 0
			' >/dev/null || die "No single age key group covers ${source}."

		done

		MACHINE="${machine}" SOURCE_PATH="${recipient_source}" SERVER_PATH="${server_recipient_source}" yq -i "
		    (.creation_rules | map(select(.path_regex as \$regex | strenv(SOURCE_PATH) | test(\$regex))) | .[0].key_groups[0].age) as \$client |
		    (.creation_rules | map(select(.path_regex as \$regex | strenv(SERVER_PATH) | test(\$regex))) | .[0].key_groups[0].age) as \$server |
		    .creation_rules += [{
		        \"path_regex\": \"^agentsview-postgres/\" + strenv(MACHINE) + \"[.]yaml\$\",
		        \"key_groups\": [{\"age\": ((\$client + \$server) | unique)}]
		    }]
		" .sops.yaml

		echo "    Added a rule for ${machine}"
		return 0
	fi

	yq -i '
	    .creation_rules += [{
	        "path_regex": "^agentsview-postgres/'"${machine}"'\\.yaml$",
	        "key_groups": [{"age": []}]
	    }] |
	    .creation_rules[-1].key_groups[0].age[0] alias = "'"${server_anchor}"'" |
	    .creation_rules[-1].key_groups[0].age[1] alias = "'"${host}"'_user"
	' .sops.yaml

	echo "    Added a rule for ${machine}"
}

# The auth token and the cursor secret every machine needs, and for a machine
# that pushes, the key of its certificate as well.
#
# Creating the file needs only the recipients' public keys. A certificate
# re-issued later has its new key added to the file that already exists, and
# updating an encrypted file means decrypting it first, so run the script on a
# machine that a rule in `.sops.yaml` covers.
generate_user_secrets() {
	local host="${1}"
	local client_key="${2:-}"

	local user_file="${host}/user-agentsview.yaml"
	local plaintext key

	mkdir -p "${host}"

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

generate_client_secrets() {
	local host="${1}"
	local machine="${2}"
	local certificate="${REPO_ROOT}/${3}"
	local password_file="${4}"
	local secrets_file="${5}"
	local recipient_source="${6:-}"
	local server_recipient_source="${7}"

	local client_key=""
	local key_file plaintext

	if [[ ! -f "${certificate}" ]] && has_secret "${secrets_file}" "agentsview_client_key"; then
		die "${secrets_file} has agentsview_client_key but ${certificate} is missing. Restore the matching certificate or remove the key before generating a new pair."
	fi

	add_password_rule "${machine}" "${host}" "${recipient_source}" "${server_recipient_source}"

	mkdir -p "agentsview-postgres"

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

	# openssl writes the key once, when it generates the certificate. If the
	# certificate is already there, the key can only be in the user file.
	if [[ -z "${client_key}" ]] && ! has_secret "${secrets_file}" "agentsview_client_key"; then
		die "${certificate} is there but ${secrets_file} has no agentsview_client_key. Delete the certificate and run this again to generate a matching pair."
	fi

	if [[ "${secrets_file}" == "${host}/user-agentsview.yaml" ]]; then
		generate_user_secrets "${host}" "${client_key}"
	elif [[ -n "${client_key}" ]]; then
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
	local host="${1}"
	local server_file="${host}/host-agentsview.yaml"

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
roles_output="$(agentsview_hosts)" || die "Could not evaluate the AgentsView hosts."
pushers_output="$(agentsview_pushers)" || die "Could not evaluate the AgentsView pushers."
if [[ -z "${roles_output}" ]]; then
	die "No host has the agentsview feature."
fi

mapfile -t roles <<<"${roles_output}"
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
	known=()
	for role in "${roles[@]}"; do
		read -r _ role_host <<<"${role}"
		known+=("${role_host}")
	done

	unknown=()
	for name in "${requested[@]}"; do
		printf '%s\n' "${known[@]}" | grep -qxF "${name}" || unknown+=("${name}")
	done

	if ((${#unknown[@]} > 0)); then
		die "no host with the agentsview feature is named: ${unknown[*]}"
	fi
fi

cd "${secrets_dir}"

generate_pusher() {
	local wanted_machine="${1}"
	local pusher

	for pusher in "${pushers[@]}"; do
		IFS=$'\t' read -r pusher_host machine certificate password_file secrets_file recipient_source server_recipient_source <<<"${pusher}"
		if [[ "${recipient_source}" == "-" ]]; then
			recipient_source=""
		fi

		if [[ "${machine}" != "${wanted_machine}" ]]; then
			continue
		fi

		generate_client_secrets \
			"${pusher_host}" \
			"${machine}" \
			"${certificate}" \
			"${password_file}" \
			"${secrets_file}" \
			"${recipient_source}" \
			"${server_recipient_source}"
		return 0
	done

	die "The evaluated AgentsView configuration has no pusher named ${wanted_machine}."
}

for role in "${roles[@]}"; do
	read -r kind host <<<"${role}"

	if ((${#requested[@]} > 0)) && ! printf '%s\n' "${requested[@]}" | grep -qxF "${host}"; then
		continue
	fi

	log_step "Generating the AgentsView secrets for ${host}"

	case "${kind}" in
	local)
		generate_user_secrets "${host}"
		;;

	client)
		generate_pusher "${host}"
		;;

	server)
		generate_pusher "${host}"
		generate_server_secrets "${host}"
		;;
	esac

	for pusher in "${pushers[@]}"; do
		IFS=$'\t' read -r pusher_host machine _ <<<"${pusher}"

		if [[ "${pusher_host}" == "${host}" && "${machine}" != "${host}" ]]; then
			log_step "Generating the AgentsView secrets for ${machine}"
			generate_pusher "${machine}"
		fi
	done
done
