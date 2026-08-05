# shellcheck shell=bash
#
# Archive a directory, encrypt it to an age recipient, and push it to Cloudflare
# R2, then expire old copies. Driven entirely by the environment so it stays a
# plain, checkable shell script:
#
#   BACKUP_SOURCE         directory to archive
#   BACKUP_NAME           leading part of the archive's name
#   BACKUP_AGE_RECIPIENT  age public key to encrypt to
#   BACKUP_PREFIX         path prefix within the bucket
#   BACKUP_KEEP_DAYS      delete remote backups older than this
#   R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
set -euo pipefail
umask 077

: "${BACKUP_SOURCE:?}" "${BACKUP_NAME:?}" "${BACKUP_AGE_RECIPIENT:?}"
: "${BACKUP_PREFIX:?}" "${BACKUP_KEEP_DAYS:?}"
: "${R2_BUCKET:?}" "${R2_ENDPOINT:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

ts="$(date -u +%Y%m%dT%H%M%SZ)"
archive="${work}/${BACKUP_NAME}-${ts}.tar.zst.age"

tar --use-compress-program='zstd -T0 -19' --numeric-owner -C "${BACKUP_SOURCE}" -cf - . |
	age -r "${BACKUP_AGE_RECIPIENT}" -o "${archive}"

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
# A scoped R2 token cannot create or probe buckets, so stop rclone from
# attempting it and upload straight into the existing bucket.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
dest="R2:${R2_BUCKET}/${BACKUP_PREFIX}"

rclone copy "${archive}" "${dest}/"
rclone delete --min-age "${BACKUP_KEEP_DAYS}d" "${dest}/" || true
