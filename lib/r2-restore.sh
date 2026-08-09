# shellcheck shell=bash
#
# Fetch a backup from Cloudflare R2, decrypt it with an age identity and unpack
# it. This half of a restore is run by hand, so it takes the job to do as its
# argument:
#
#   r2-restore list   print the backups held, newest last
#   r2-restore fetch  unpack one of them and print the name it used
#
# Progress goes to stderr and that name to stdout, so the caller can act on it.
# The rest arrives in the environment:
#
#   BACKUP_NAME           leading part of the archive's name
#   BACKUP_PREFIX         path prefix within the bucket
#   BACKUP_IDENTITY_FILE  age identity file holding the private key
#   BACKUP_RESTORE_DIR    directory to unpack into
#   BACKUP_ARCHIVE        backup to fetch, defaulting to the newest
#   R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
set -euo pipefail
umask 077

: "${BACKUP_NAME:?}" "${BACKUP_PREFIX:?}"
: "${R2_BUCKET:?}" "${R2_ENDPOINT:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"

fail() {
	echo "r2-restore: $*" >&2
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

# One bucket serves every backup, so ask for this service's archives alone. The
# name ends in a fixed-width UTC timestamp, so the newest sorts last.
archives() {
	rclone lsf --files-only --include "${BACKUP_NAME}-*" "${dest}/" | sort
}

fetch() {
	: "${BACKUP_IDENTITY_FILE:?}" "${BACKUP_RESTORE_DIR:?}"

	local archive

	[ -r "${BACKUP_IDENTITY_FILE}" ] ||
		fail "cannot read the age identity file ${BACKUP_IDENTITY_FILE}"

	archive="${BACKUP_ARCHIVE:-}"

	if [ -z "${archive}" ]; then
		archive="$(archives | tail -n 1)"
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
list)
	archives
	;;
fetch)
	fetch
	;;
*)
	fail "usage: r2-restore list|fetch"
	;;
esac
