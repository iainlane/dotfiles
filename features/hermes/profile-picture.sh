# shellcheck shell=bash
#
# Select a profile picture from the source (a single image or a directory of
# images) and apply it to each enabled messaging platform. Rotation avoids
# repeating the last-applied image. Best-effort: a platform being unreachable is
# logged and skipped, and the rotation marker only advances once the chosen
# image has actually been applied everywhere.

source_path="${PROFILE_PICTURE_SOURCE}"
state_dir="${PROFILE_PICTURE_STATE_DIR}"
current_hash_file="${state_dir}/current.sha256"

# Apply the image to the bot's Matrix profile (avatar and, if set, display
# name), then drop the transient login session so it does not accumulate as an
# unverified device on the account.
update_matrix() {
	local image="$1"
	local ready="" login_body access_token user_id_path mime_type content_uri rc=0

	for _ in $(seq 1 30); do
		if curl -fsS "${MATRIX_HOMESERVER}/_matrix/client/versions" >/dev/null 2>&1; then
			ready=1
			break
		fi
		sleep 2
	done
	if [ -z "${ready}" ]; then
		echo "profile-picture: matrix homeserver not reachable, skipping" >&2
		return 1
	fi

	login_body="$(jq -n --arg user "${MATRIX_USER_ID}" --arg password "${MATRIX_PASSWORD}" \
		'{type: "m.login.password", identifier: {type: "m.id.user", user: $user}, password: $password}')"
	access_token="$(curl -fsS -H "Content-Type: application/json" --data "${login_body}" \
		"${MATRIX_HOMESERVER}/_matrix/client/v3/login" | jq -r '.access_token // empty')"
	if [ -z "${access_token}" ]; then
		echo "profile-picture: matrix login failed, skipping" >&2
		return 1
	fi

	user_id_path="$(printf '%s' "${MATRIX_USER_ID}" | jq -sRr @uri)"

	mime_type="$(file --brief --mime-type "${image}")"
	content_uri="$(curl -fsS -X POST -H "Authorization: Bearer ${access_token}" \
		-H "Content-Type: ${mime_type}" --data-binary "@${image}" \
		"${MATRIX_HOMESERVER}/_matrix/media/v3/upload?filename=profile-picture" | jq -r '.content_uri // empty')"
	if [ -n "${content_uri}" ]; then
		if ! curl -fsS -X PUT -H "Authorization: Bearer ${access_token}" -H "Content-Type: application/json" \
			--data "$(jq -n --arg avatar_url "${content_uri}" '{avatar_url: $avatar_url}')" \
			"${MATRIX_HOMESERVER}/_matrix/client/v3/profile/${user_id_path}/avatar_url" >/dev/null; then
			echo "profile-picture: matrix avatar update failed" >&2
			rc=1
		fi
	else
		echo "profile-picture: matrix media upload failed" >&2
		rc=1
	fi

	if [ -n "${MATRIX_DISPLAY_NAME:-}" ]; then
		if ! curl -fsS -X PUT -H "Authorization: Bearer ${access_token}" -H "Content-Type: application/json" \
			--data "$(jq -n --arg displayname "${MATRIX_DISPLAY_NAME}" '{displayname: $displayname}')" \
			"${MATRIX_HOMESERVER}/_matrix/client/v3/profile/${user_id_path}/displayname" >/dev/null; then
			echo "profile-picture: matrix display name update failed" >&2
			rc=1
		fi
	fi

	curl -fsS -X POST -H "Authorization: Bearer ${access_token}" --data '{}' \
		"${MATRIX_HOMESERVER}/_matrix/client/v3/logout" >/dev/null 2>&1 ||
		echo "profile-picture: matrix logout failed (transient device may linger)" >&2

	return "${rc}"
}

# Apply the image to the bot's Signal profile via the signal-cli daemon. The
# daemon reads the path itself, so the same image is mounted into its container.
update_signal() {
	local image="$1"
	local request response

	for _ in $(seq 1 30); do
		if curl -fsS "${SIGNAL_HTTP_URL}/api/v1/check" >/dev/null 2>&1; then
			break
		fi
		sleep 2
	done

	request="$(jq -n --arg account "${SIGNAL_ACCOUNT}" --arg avatar "${image}" \
		'{jsonrpc: "2.0", id: "profile-picture", method: "updateProfile", params: {account: $account, avatar: $avatar}}')"
	response="$(curl -fsS -H "Content-Type: application/json" --data "${request}" "${SIGNAL_HTTP_URL}/api/v1/rpc")"
	if [ -z "${response}" ]; then
		echo "profile-picture: signal rpc call failed" >&2
		return 1
	fi
	if [ "$(printf '%s' "${response}" | jq 'has("error")')" = "true" ]; then
		echo "profile-picture: signal updateProfile error: ${response}" >&2
		return 1
	fi
	return 0
}

install -d -m 0700 "${state_dir}"

if [ -f "${source_path}" ]; then
	candidates=("${source_path}")
else
	mapfile -d "" -t candidates < <(
		find "${source_path}" -maxdepth 1 -type f \
			\( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" \) \
			-print0 |
			sort -z
	)
fi

if [ "${#candidates[@]}" -eq 0 ]; then
	echo "profile-picture: no images found in ${source_path}, nothing to do" >&2
	exit 0
fi

current_hash=""
if [ -f "${current_hash_file}" ]; then
	current_hash="$(cat "${current_hash_file}")"
fi

eligible=()
eligible_hashes=()
for candidate in "${candidates[@]}"; do
	candidate_hash="$(sha256sum "${candidate}" | cut -d " " -f 1)"

	if [ "${#candidates[@]}" -gt 1 ] && [ "${candidate_hash}" = "${current_hash}" ]; then
		continue
	fi

	eligible+=("${candidate}")
	eligible_hashes+=("${candidate_hash}")
done

if [ "${#eligible[@]}" -eq 0 ]; then
	eligible=("${candidates[@]}")
	eligible_hashes=()

	for candidate in "${eligible[@]}"; do
		eligible_hashes+=("$(sha256sum "${candidate}" | cut -d " " -f 1)")
	done
fi

selected_index="$(shuf -i "0-$((${#eligible[@]} - 1))" -n 1)"
selected_image="${eligible[${selected_index}]}"
selected_hash="${eligible_hashes[${selected_index}]}"

ok=true

if [ "${MATRIX_PROFILE_PICTURE_ENABLED:-false}" = "true" ]; then
	if ! update_matrix "${selected_image}"; then
		ok=false
	fi
fi

if [ "${SIGNAL_PROFILE_PICTURE_ENABLED:-false}" = "true" ]; then
	if ! update_signal "${selected_image}"; then
		ok=false
	fi
fi

if [ "${ok}" = "true" ]; then
	printf "%s\n" "${selected_hash}" >"${current_hash_file}"
else
	echo "profile-picture: some updates failed; rotation state left unchanged" >&2
fi
