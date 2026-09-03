# shellcheck shell=bash
#
# Archive a directory to Cloudflare R2, check that one arrived, and restore
# one. The three share every setting but BACKUP_SOURCE, so they share one
# script and one dispatch on the first argument:
#
#   r2 backup          archive a directory, encrypt it, and push it to R2,
#                      then expire old copies
#   r2 verify          check that a recent, plausible-looking backup is
#                      sitting in R2
#   r2 restore list    print the backups held, newest last
#   r2 restore fetch   fetch one, decrypt it, and unpack it
#
# All four read, driven entirely by the environment so this stays a plain,
# checkable shell script:
#
#   BACKUP_NAME           leading part of the archive's name
#   BACKUP_PREFIX         path prefix within the bucket
#   R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
#
# backup also reads:
#   BACKUP_SOURCE         directory to archive
#   BACKUP_AGE_RECIPIENT  age public key to encrypt to
#   BACKUP_KEEP_DAYS      delete remote backups older than this
#
# verify also reads:
#   BACKUP_MAX_AGE_HOURS  fail if the newest backup is older than this
#   BACKUP_MIN_SIZE       fail if the newest backup is smaller than this
#   BACKUP_MIN_COUNT      fail if fewer backups than this are held
#
# restore fetch also reads:
#   BACKUP_IDENTITY_FILE  age identity file holding the private key
#   BACKUP_RESTORE_DIR    directory to unpack into
#   BACKUP_ARCHIVE        backup to fetch, defaulting to the newest
set -euo pipefail
umask 077

: "${BACKUP_NAME:?}" "${BACKUP_PREFIX:?}"
: "${R2_BUCKET:?}" "${R2_ENDPOINT:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"

fail() {
	echo "r2: $*" >&2
	exit 1
}

# All configuration is supplied via environment variables, so rclone never needs a config file.
export RCLONE_CONFIG=/dev/null
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
# A scoped R2 token cannot create or probe buckets, so stop rclone from
# attempting it and work straight against the existing bucket.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
dest="R2:${R2_BUCKET}/${BACKUP_PREFIX}"

backup() {
	: "${BACKUP_SOURCE:?}" "${BACKUP_AGE_RECIPIENT:?}" "${BACKUP_KEEP_DAYS:?}"

	local ts archive

	work="$(mktemp -d)"
	trap 'rm -rf "${work}"' EXIT

	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	archive="${work}/${BACKUP_NAME}-${ts}.tar.zst.age"

	tar --use-compress-program='zstd -T0 -9' --numeric-owner -C "${BACKUP_SOURCE}" -cf - . |
		age -r "${BACKUP_AGE_RECIPIENT}" -o "${archive}"

	rclone copy "${archive}" "${dest}/"
	rclone delete --min-age "${BACKUP_KEEP_DAYS}d" "${dest}/" || true
}

verify() {
	: "${BACKUP_MAX_AGE_HOURS:?}" "${BACKUP_MIN_SIZE:?}" "${BACKUP_MIN_COUNT:?}"

	local listing count name size uploaded age_hours

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
}

# One bucket serves every backup, so ask for this service's archives alone. The
# name ends in a fixed-width UTC timestamp, so the newest sorts last.
restore_list() {
	rclone lsf --files-only --include "${BACKUP_NAME}-*" "${dest}/" | sort
}

restore_fetch() {
	: "${BACKUP_IDENTITY_FILE:?}" "${BACKUP_RESTORE_DIR:?}"

	local archive

	[ -r "${BACKUP_IDENTITY_FILE}" ] ||
		fail "cannot read the age identity file ${BACKUP_IDENTITY_FILE}"

	work="$(mktemp -d)"
	trap 'rm -rf "${work}"' EXIT

	archive="${BACKUP_ARCHIVE:-}"

	if [ -z "${archive}" ]; then
		archive="$(restore_list | tail -n 1)"
	fi

	[ -n "${archive}" ] || fail "no ${BACKUP_NAME} backups under ${dest}"

	echo "fetching ${archive}" >&2
	rclone copyto "${dest}/${archive}" "${work}/${archive}"

	mkdir -p "${BACKUP_RESTORE_DIR}"

	echo "decrypting into ${BACKUP_RESTORE_DIR}" >&2
	age -d -i "${BACKUP_IDENTITY_FILE}" "${work}/${archive}" |
		tar --use-compress-program=zstd --numeric-owner -C "${BACKUP_RESTORE_DIR}" -xf -

	echo "${archive}"
}

case "${1:-}" in
backup)
	backup
	;;
verify)
	verify
	;;
restore)
	case "${2:-}" in
	list)
		restore_list
		;;
	fetch)
		restore_fetch
		;;
	*)
		fail "usage: r2 restore list|fetch"
		;;
	esac
	;;
*)
	fail "usage: r2 backup|verify|restore"
	;;
esac
