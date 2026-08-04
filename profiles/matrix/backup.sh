# shellcheck shell=bash
#
# Ask the homeserver for an online database backup, wait for it to land, and
# hand the result to the uploader.
#
#   MATRIX_CONTAINER      container to signal
#   MATRIX_BACKUP_VOLUME  podman volume the backups are written to
#   MATRIX_BACKUP_TIMEOUT seconds to wait for one to appear
#
# plus everything `r2-upload` reads.
set -euo pipefail

: "${MATRIX_CONTAINER:?}" "${MATRIX_BACKUP_VOLUME:?}" "${MATRIX_BACKUP_TIMEOUT:?}"

dir="$(podman volume inspect --format '{{.Mountpoint}}' "${MATRIX_BACKUP_VOLUME}")"

# The backup engine writes a file under `meta` once every other file of that
# backup is in place, and names it after the backup's number, so the highest
# one is the newest complete backup.
latest() {
	local newest=0 name path

	for path in "${dir}"/meta/*; do
		name="${path##*/}"

		case "${name}" in
		*[!0-9]* | "")
			continue
			;;
		esac

		if [ "${name}" -gt "${newest}" ]; then
			newest="${name}"
		fi
	done

	echo "${newest}"
}

before="$(latest)"

# SIGUSR2 runs the homeserver's `admin_signal_execute` commands. It returns
# straight away and the backup proceeds in the background.
podman kill --signal USR2 "${MATRIX_CONTAINER}"

waited=0
while [ "$(latest)" = "${before}" ]; do
	if [ "${waited}" -ge "${MATRIX_BACKUP_TIMEOUT}" ]; then
		echo "no new backup after ${MATRIX_BACKUP_TIMEOUT}s; still at ${before}" >&2
		exit 1
	fi

	sleep 5
	waited=$((waited + 5))
done

echo "backup $(latest) complete after ${waited}s"

BACKUP_SOURCE="${dir}" exec r2-upload
