# shellcheck shell=bash
#
# Snapshot the UniFi controller's state volumes and hand the result to
# `r2 backup`.
#
#   UNIFI_CONTAINER  container to stop for the duration
#   UNIFI_VOLUMES    space-separated podman volumes to archive
#
# plus everything `r2 backup` reads.
#
# The controller keeps its configuration in mongodb, which is copied while
# nothing is writing to it. Stopping the container is what gives that, so the
# archive is taken from the volume mount points while the controller is down.
set -euo pipefail
umask 077

: "${UNIFI_CONTAINER:?}" "${UNIFI_VOLUMES:?}"

work="$(mktemp -d)"
snap="${work}/snapshot"

started=0

restart() {
	if [ "${started}" -eq 1 ]; then
		systemctl start "${UNIFI_CONTAINER}.service"
	fi

	rm -rf "${work}"
}

trap restart EXIT

if systemctl is-active --quiet "${UNIFI_CONTAINER}.service"; then
	started=1
	systemctl stop "${UNIFI_CONTAINER}.service"
fi

for volume in ${UNIFI_VOLUMES}; do
	mountpoint="$(podman volume inspect --format '{{.Mountpoint}}' "${volume}")"
	install -d -m 0700 "${snap}/${volume}"
	rsync -a --numeric-ids "${mountpoint}/" "${snap}/${volume}/"
done

BACKUP_SOURCE="${snap}" r2 backup
