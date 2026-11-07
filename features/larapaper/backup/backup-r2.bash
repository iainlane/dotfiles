# shellcheck shell=bash
#
# Snapshot the LaraPaper database and generated images into one directory and
# hand it to `r2 backup`. Every setting arrives in the environment, so nothing
# is substituted into this file and shellcheck can run over it:
#
#   LARAPAPER_DATABASE_VOLUME  podman volume that contains the SQLite database
#   LARAPAPER_STORAGE_VOLUME   podman volume that contains the generated images
#   LARAPAPER_DATABASE_FILE    name of the SQLite file within the database volume
#
# plus everything `r2 backup` reads.
set -euo pipefail
umask 077

: "${LARAPAPER_DATABASE_VOLUME:?}" "${LARAPAPER_STORAGE_VOLUME:?}" "${LARAPAPER_DATABASE_FILE:?}"

database_dir="$(podman volume inspect --format '{{.Mountpoint}}' "${LARAPAPER_DATABASE_VOLUME}")"
storage_dir="$(podman volume inspect --format '{{.Mountpoint}}' "${LARAPAPER_STORAGE_VOLUME}")"

database="${database_dir}/${LARAPAPER_DATABASE_FILE}"
if [ ! -f "${database}" ]; then
	echo "no database at ${database}" >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
snap="${work}/snapshot"
mkdir -p "${snap}/database/storage" "${snap}/storage/app/public/images/generated"

# The live database is copied with the SQLite online backup API, so the copy is
# consistent even while the container writes to it.
sqlite3 "${database}" ".backup '${snap}/database/storage/${LARAPAPER_DATABASE_FILE}'"

# The generated images are plain files, so a copy of the directory is enough.
rsync -a --numeric-ids "${storage_dir}/" "${snap}/storage/app/public/images/generated/"

BACKUP_SOURCE="${snap}" r2 backup
