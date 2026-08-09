# shellcheck shell=bash
#
# Check that a recent backup is sitting in Cloudflare R2. The private half of
# the age key is offline, so the host cannot open what it uploaded; what it can
# establish is that an object of a plausible size arrived recently and that the
# history behind it is still there. Driven entirely by the environment so it
# stays a plain, checkable shell script:
#
#   BACKUP_NAME           leading part of the archive's name
#   BACKUP_PREFIX         path prefix within the bucket
#   BACKUP_MAX_AGE_HOURS  fail if the newest backup is older than this
#   BACKUP_MIN_SIZE       fail if the newest backup is smaller than this
#   BACKUP_MIN_COUNT      fail if fewer backups than this are held
#   R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
set -euo pipefail
umask 077

: "${BACKUP_NAME:?}" "${BACKUP_PREFIX:?}" "${BACKUP_MAX_AGE_HOURS:?}"
: "${BACKUP_MIN_SIZE:?}" "${BACKUP_MIN_COUNT:?}"
: "${R2_BUCKET:?}" "${R2_ENDPOINT:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"

fail() {
	echo "backup verification failed: $*" >&2
	exit 1
}

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
# A scoped R2 token cannot create or probe buckets, so stop rclone from
# attempting it and read straight from the existing bucket.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
dest="R2:${R2_BUCKET}/${BACKUP_PREFIX}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

listing="${work}/listing.json"

# One bucket serves every backup, so ask for this service's archives alone.
if ! rclone lsjson --files-only --include "${BACKUP_NAME}-*" "${dest}/" >"${listing}"; then
	fail "cannot list ${dest}"
fi

count="$(jq 'length' "${listing}")"

if [ "${count}" -eq 0 ]; then
	fail "no ${BACKUP_NAME} backups under ${dest}"
fi

if [ "${count}" -lt "${BACKUP_MIN_COUNT}" ]; then
	fail "${dest} holds ${count} backups, expected at least ${BACKUP_MIN_COUNT}"
fi

# The name ends in a fixed-width UTC timestamp, so the newest sorts last.
IFS=$'\t' read -r name size uploaded < <(
	jq -r 'sort_by(.Name) | last | [.Name, .Size, .ModTime] | @tsv' "${listing}"
)

age_hours=$((($(date -u +%s) - $(date -u -d "${uploaded}" +%s)) / 3600))

if [ "${age_hours}" -gt "${BACKUP_MAX_AGE_HOURS}" ]; then
	fail "${name} is ${age_hours}h old, past the ${BACKUP_MAX_AGE_HOURS}h threshold"
fi

if [ "${size}" -lt "${BACKUP_MIN_SIZE}" ]; then
	fail "${name} is ${size} bytes, under the ${BACKUP_MIN_SIZE} byte floor"
fi

echo "${name}: ${size} bytes, ${age_hours}h old, ${count} kept under ${dest}"
