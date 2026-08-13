#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils gnugrep jq openssl sops yq-go
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Generate the secrets that a machine needs for AgentsView.
#
# Every machine that keeps an archive of its agent sessions needs two values
# that AgentsView would otherwise generate for itself. Nix renders its
# configuration read-only, so both come from here:
#
#   <host>/user-agentsview.yaml       agentsview_auth_token
#                                     agentsview_cursor_secret
#
# A machine that also pushes its archive to the shared database needs a
# password, a certificate, and the key of that certificate:
#
#   agentsview-postgres/<host>.yaml   password
#   <host>/user-agentsview.yaml       agentsview_client_key
#   hosts/<host>/agentsview.pem       the certificate that the proxy checks
#
# The machine that holds the database and shows the dashboard needs four more:
#
#   <host>/host-agentsview.yaml       agentsview_superuser_password
#                                     agentsview_dashboard_password
#                                     agentsview_auth_token
#                                     agentsview_cursor_secret
#
# The flake says which machines these are, so name a host only to limit the
# run to it. This script makes each value that a host does not have yet and
# leaves the others alone.
#
# A new file needs the public keys alone, thus you can make one for any host.
# To add a key to a file that is already there, sops decrypts it first, so run
# the script on a machine that the rule in `.sops.yaml` covers. Reading which
# keys a file holds needs nothing, because sops encrypts the values and leaves
# the keys in plain text.
#
# Usage: generate-agentsview-secrets [host...] <secrets_dir>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

secrets_dir="${*: -1}"
requested=("${@:1:$#-1}")

# The server reads the password of every machine to keep the roles in line, so
# its host key joins the user of the machine on the password file. The user
# file needs no rule of its own, because `^<host>/user-.*\.yaml$` covers it.
server_anchor="ancaster_host"

# Whether an encrypted file already holds a key. sops encrypts the values and
# leaves the keys in plain text, thus this reads the file as it stands.
has_secret() {
	local path="${1}"
	local key="${2}"

	[[ -f "${path}" ]] && yq -e 'has("'"${key}"'")' "${path}" >/dev/null 2>&1
}

# Add one key to a file that is already encrypted. sops reads the value from
# stdin, thus the value stays out of the process list.
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

# The rule that lets the server and the machine itself read the password.
add_password_rule() {
	local host="${1}"

	if yq -e '.creation_rules[] | select(.path_regex == "^agentsview-postgres/'"${host}"'\.yaml$")' .sops.yaml >/dev/null 2>&1; then
		echo "    .sops.yaml already covers ${host}"
		return 0
	fi

	yq -i '
	    .creation_rules += [{
	        "path_regex": "^agentsview-postgres/'"${host}"'\\.yaml$",
	        "key_groups": [{"age": []}]
	    }] |
	    .creation_rules[-1].key_groups[0].age[0] alias = "'"${server_anchor}"'" |
	    .creation_rules[-1].key_groups[0].age[1] alias = "'"${host}"'_user" |
	    .creation_rules |= sort_by(.path_regex)
	' .sops.yaml

	echo "    Added a rule for ${host}"
}

# The auth token and the cursor secret every machine needs, and for a machine
# that pushes, the key of its certificate as well.
#
# The certificate key goes in when the file is created. Creating an encrypted
# file needs only the public keys, whereas adding a key to an existing file
# means decrypting it first, which works only on a machine that a rule in
# `.sops.yaml` covers.
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

	plaintext="$(make_temp_file)"
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

	encrypt_yaml_file "${plaintext}" "${user_file}" "${user_file}"
	echo "    Created ${user_file}"
}

generate_client_secrets() {
	local host="${1}"

	local certificate="${REPO_ROOT}/hosts/${host}/agentsview.pem"
	local password_file="agentsview-postgres/${host}.yaml"
	local user_file="${host}/user-agentsview.yaml"

	local client_key=""
	local key_file plaintext

	add_password_rule "${host}"

	mkdir -p "agentsview-postgres"

	if [[ -f "${certificate}" ]]; then
		echo "    ${certificate} is already there"
	else
		key_file="$(make_temp_file)"
		mkdir -p "$(dirname "${certificate}")"

		# By default, openssl writes the full curve parameters. Go rejects a
		# key of that form, so the command asks for the named-curve encoding.
		openssl req -x509 -newkey ec \
			-pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve \
			-nodes -days 36500 -subj "/CN=${host}" \
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
		plaintext="$(make_temp_file)"
		PASSWORD="$(openssl rand -hex 32)" yq -n '.password = strenv(PASSWORD)' >"${plaintext}"
		encrypt_yaml_file "${plaintext}" "${password_file}" "${password_file}"
		echo "    Created ${password_file}"
	fi

	# openssl writes the key once, when it generates the certificate. If the
	# certificate is already there, the key can only be in the user file.
	if [[ ! -f "${user_file}" && -z "${client_key}" ]]; then
		die "${certificate} is there and ${user_file} is not. Delete the certificate and run this again to make a matching pair."
	fi

	generate_user_secrets "${host}" "${client_key}"
}

generate_server_secrets() {
	local host="${1}"
	local server_file="${host}/host-agentsview.yaml"

	local plaintext key

	# Both passwords go into a connection URL, where `/`, `#`, `?` and `:`
	# read as a port or a path. Hex avoids them all.
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

	plaintext="$(make_temp_file)"
	: >"${plaintext}"

	for key in "${!secrets[@]}"; do
		SECRET_KEY="${key}" SECRET_VALUE="${secrets[${key}]}" \
			yq -i '.[strenv(SECRET_KEY)] = strenv(SECRET_VALUE)' "${plaintext}"
	done

	encrypt_yaml_file "${plaintext}" "${server_file}" "${server_file}"
	echo "    Created ${server_file}"
}

log_step "Reading the host records"
mapfile -t roles < <(agentsview_hosts)

if ((${#roles[@]} == 0)); then
	die "No host has the agentsview profile."
fi

cd "${secrets_dir}"

for role in "${roles[@]}"; do
	read -r kind host <<<"${role}"

	if ((${#requested[@]} > 0)) && ! printf '%s\n' "${requested[@]}" | grep -qxF "${host}"; then
		continue
	fi

	log_step "Making the AgentsView secrets for ${host}"

	case "${kind}" in
	local)
		generate_user_secrets "${host}"
		;;

	client)
		generate_client_secrets "${host}"
		;;

	server)
		generate_client_secrets "${host}"
		generate_server_secrets "${host}"
		;;
	esac
done
