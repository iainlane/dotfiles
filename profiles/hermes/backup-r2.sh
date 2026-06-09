# shellcheck shell=bash
#
# Snapshot the Hermes state, encrypt it to an age recipient, and push it to
# Cloudflare R2. Driven entirely by the environment so it stays a plain,
# checkable shell script:
#
#   HERMES_STATE_DIR             state directory to back up, or
#   HERMES_STATE_VOLUME          podman volume whose mountpoint to back up
#   HERMES_BACKUP_AGE_RECIPIENT  age public key to encrypt to
#   HERMES_BACKUP_PREFIX         path prefix within the bucket
#   HERMES_BACKUP_KEEP_DAYS      delete remote backups older than this
#   R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
set -euo pipefail
umask 077

# The state lives in a podman named volume; resolve its host mountpoint.
if [ -z "${HERMES_STATE_DIR:-}" ] && [ -n "${HERMES_STATE_VOLUME:-}" ]; then
	HERMES_STATE_DIR="$(podman volume inspect --format '{{.Mountpoint}}' "${HERMES_STATE_VOLUME}")"
fi

: "${HERMES_STATE_DIR:?}" "${HERMES_BACKUP_AGE_RECIPIENT:?}"
: "${HERMES_BACKUP_PREFIX:?}" "${HERMES_BACKUP_KEEP_DAYS:?}"
: "${R2_BUCKET:?}" "${R2_ENDPOINT:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"

work="$(mktemp -d)"
# The snapshot copies Hermes' read-only bundled skills, whose leaf
# directories drop owner-write, so restore it before removing the tree.
trap 'chmod -R u+w "${work}" 2>/dev/null || true; rm -rf "${work}"' EXIT
snap="${work}/snapshot"
mkdir -p "${snap}/.hermes"

# Copy everything except the live SQLite databases. Those are captured
# consistently below with the SQLite online backup API.
rsync -a --numeric-ids \
	--exclude=/current-package \
	--exclude='/.hermes/state.db*' \
	--exclude='/.hermes/memory_store.db*' \
	--exclude='/.hermes/kanban.db-wal' \
	--exclude='/.hermes/kanban.db-shm' \
	"${HERMES_STATE_DIR}/" "${snap}/"

for db in state.db memory_store.db kanban.db; do
	src="${HERMES_STATE_DIR}/.hermes/${db}"
	if [ -f "${src}" ]; then
		sqlite3 "${src}" ".backup '${snap}/.hermes/${db}'"
	fi
done

ts="$(date -u +%Y%m%dT%H%M%SZ)"
archive="${work}/hermes-${ts}.tar.zst.age"
tar --use-compress-program='zstd -T0 -19' -C "${snap}" -cf - . |
	age -r "${HERMES_BACKUP_AGE_RECIPIENT}" -o "${archive}"

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
# A scoped R2 token cannot create or probe buckets, so stop rclone from
# attempting it and upload straight into the existing bucket.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
dest="R2:${R2_BUCKET}/${HERMES_BACKUP_PREFIX}"

rclone copy "${archive}" "${dest}/"
rclone delete --min-age "${HERMES_BACKUP_KEEP_DAYS}d" "${dest}/" || true
