readonly app_bundle="/Applications/Voxtype.app"
readonly app_binary="${app_bundle}/Contents/MacOS/voxtype-bin"
readonly bundle_identifier="io.voxtype.daemon"
launch_agent_domain="gui/$(/usr/bin/id -u)"
readonly launch_agent_domain
readonly launch_agent_plist="${HOME}/Library/LaunchAgents/${bundle_identifier}.plist"
readonly launch_agent_target="${launch_agent_domain}/${bundle_identifier}"
signing_keychain=
signing_identity_hash=
signing_requirement=

import_signing_identity() {
	if ! signing_keychain=$(/usr/bin/security default-keychain -d user); then
		echo "Could not find the default Keychain for ${USER}" >&2
		return 1
	fi

	signing_keychain="${signing_keychain#*\"}"
	signing_keychain="${signing_keychain%\"*}"

	if [[ -z ${signing_keychain} || ! -f ${signing_keychain} ]]; then
		echo "The default Keychain for ${USER} does not exist: ${signing_keychain}" >&2
		return 1
	fi

	local signing_directory
	signing_directory=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/voxtype-signing.XXXXXX")
	local identity_file="${signing_directory}/identity.p12"
	local certificate_file="${signing_directory}/certificate.pem"

	if ! /usr/bin/base64 -D -i "${identity_secret}" -o "${identity_file}"; then
		/bin/rm -rf "${signing_directory}"
		return 1
	fi

	if ! openssl pkcs12 \
		-legacy \
		-in "${identity_file}" \
		-passin "file:${password_secret}" \
		-clcerts \
		-nokeys \
		-out "${certificate_file}"; then
		/bin/rm -rf "${signing_directory}"
		return 1
	fi

	local fingerprint
	if ! fingerprint=$(openssl x509 -in "${certificate_file}" -noout -fingerprint -sha1); then
		/bin/rm -rf "${signing_directory}"
		return 1
	fi

	signing_identity_hash=${fingerprint#*=}
	signing_identity_hash=${signing_identity_hash//:/}

	if [[ ! ${signing_identity_hash} =~ ^[[:xdigit:]]{40}$ ]]; then
		echo "Could not read the code-signing certificate fingerprint" >&2
		/bin/rm -rf "${signing_directory}"
		return 1
	fi

	local lower_identity_hash
	if ! lower_identity_hash=$(/usr/bin/printf '%s' "${signing_identity_hash}" | /usr/bin/tr '[:upper:]' '[:lower:]'); then
		/bin/rm -rf "${signing_directory}"
		return 1
	fi

	signing_requirement="identifier \"${bundle_identifier}\" and certificate root = H\"${lower_identity_hash}\""

	if /usr/bin/security find-identity -v -p codesigning "${signing_keychain}" | /usr/bin/grep -q "${signing_identity_hash}"; then
		/bin/rm -rf "${signing_directory}"
		return
	fi

	if ! /usr/bin/security find-identity -p codesigning "${signing_keychain}" | /usr/bin/grep -q "${signing_identity_hash}"; then
		local identity_password
		if ! identity_password=$(/bin/cat "${password_secret}"); then
			/bin/rm -rf "${signing_directory}"
			return 1
		fi

		if ! /usr/bin/security import "${identity_file}" \
			-k "${signing_keychain}" \
			-P "${identity_password}" \
			-T /usr/bin/codesign; then
			/bin/rm -rf "${signing_directory}"
			return 1
		fi
	fi

	if ! /usr/bin/security add-trusted-cert \
		-r trustRoot \
		-p codeSign \
		-k "${signing_keychain}" \
		"${certificate_file}"; then
		/bin/rm -rf "${signing_directory}"
		return 1
	fi

	/bin/rm -rf "${signing_directory}"

	if /usr/bin/security find-identity -v -p codesigning "${signing_keychain}" | /usr/bin/grep -q "${signing_identity_hash}"; then
		return
	fi

	echo "The SOPS identity was imported but is not valid for code signing" >&2
	return 1
}

installed_bundle_is_current() {
	local marker="${app_bundle}/Contents/Resources/NixStorePath"

	if [[ ! -x ${app_binary} || ! -f ${marker} ]]; then
		return 1
	fi

	if [[ $(/bin/cat "${marker}") != "${source_bundle}" ]]; then
		return 1
	fi

	/usr/bin/codesign \
		--verify \
		--deep \
		--strict \
		-R="${signing_requirement}" \
		"${app_bundle}" >/dev/null 2>&1
}

stop_voxtype() {
	if ! /bin/launchctl print "${launch_agent_target}" >/dev/null 2>&1; then
		return
	fi

	/bin/launchctl bootout "${launch_agent_target}"
}

start_voxtype() {
	if [[ ! -f ${launch_agent_plist} ]]; then
		echo "Could not find the Voxtype launch agent: ${launch_agent_plist}" >&2
		return 1
	fi

	if /bin/launchctl print "${launch_agent_target}" >/dev/null 2>&1; then
		/bin/launchctl kickstart -k "${launch_agent_target}"
		return
	fi

	/bin/launchctl bootstrap "${launch_agent_domain}" "${launch_agent_plist}"
}

install_voxtype_app() {
	if installed_bundle_is_current; then
		return
	fi

	local staging_directory
	staging_directory=$(/usr/bin/mktemp -d "/Applications/.voxtype.XXXXXX")
	local staged_app="${staging_directory}/Voxtype.app"
	local previous_app="${staging_directory}/Voxtype.previous.app"
	local staged_binary="${staged_app}/Contents/MacOS/voxtype-bin"
	local staged_webgpu_runtime="${staged_app}/Contents/Frameworks/libwebgpu_dawn.dylib"
	local marker="${staged_app}/Contents/Resources/NixStorePath"

	if ! /usr/bin/ditto "${source_bundle}" "${staged_app}"; then
		/bin/rm -rf "${staging_directory}"
		return 1
	fi

	if ! /bin/chmod -R u+w "${staged_app}"; then
		/bin/rm -rf "${staging_directory}"
		return 1
	fi

	if ! /usr/bin/printf '%s\n' "${source_bundle}" >"${marker}"; then
		/bin/rm -rf "${staging_directory}"
		return 1
	fi

	if [[ -f ${staged_webgpu_runtime} ]] && ! /usr/bin/codesign \
		--force \
		--keychain "${signing_keychain}" \
		--sign "${signing_identity_hash}" \
		--identifier "${bundle_identifier}" \
		--timestamp=none \
		"${staged_webgpu_runtime}"; then
		/bin/rm -rf "${staging_directory}"
		return 1
	fi

	if ! /usr/bin/codesign \
		--force \
		--keychain "${signing_keychain}" \
		--sign "${signing_identity_hash}" \
		--identifier "${bundle_identifier}" \
		--timestamp=none \
		"${staged_binary}"; then
		/bin/rm -rf "${staging_directory}"
		return 1
	fi

	if ! /usr/bin/codesign \
		--force \
		--keychain "${signing_keychain}" \
		--sign "${signing_identity_hash}" \
		--identifier "${bundle_identifier}" \
		--timestamp=none \
		"${staged_app}"; then
		/bin/rm -rf "${staging_directory}"
		return 1
	fi

	if ! /usr/bin/codesign \
		--verify \
		--deep \
		--strict \
		-R="${signing_requirement}" \
		"${staged_app}"; then
		/bin/rm -rf "${staging_directory}"
		return 1
	fi

	if [[ -e ${app_bundle} ]]; then
		if ! /bin/mv "${app_bundle}" "${previous_app}"; then
			/bin/rm -rf "${staging_directory}"
			return 1
		fi
	fi

	if /bin/mv "${staged_app}" "${app_bundle}"; then
		/bin/rm -rf "${staging_directory}"
		return
	fi

	if [[ -e ${previous_app} ]]; then
		/bin/mv "${previous_app}" "${app_bundle}"
	fi

	/bin/rm -rf "${staging_directory}"
	return 1
}

main() {
	if (($# != 3)); then
		echo "Usage: ${0} SOURCE_BUNDLE IDENTITY_SECRET PASSWORD_SECRET" >&2
		return 2
	fi

	readonly source_bundle="${1}"
	readonly identity_secret="${2}"
	readonly password_secret="${3}"

	if [[ ! -d ${source_bundle} ]]; then
		echo "The Voxtype package does not contain ${source_bundle}" >&2
		return 1
	fi

	if ! import_signing_identity; then
		return 1
	fi

	if ! stop_voxtype; then
		return 1
	fi

	if ! install_voxtype_app; then
		return 1
	fi

	start_voxtype
}

main "$@"
