# shellcheck shell=bash
#
# Put a Hermes state backup back into the state volume. The backups are
# encrypted to an age recipient whose private key is kept offline, so the key
# file comes in on the command line:
#
#   hermes-restore-r2 --list
#   hermes-restore-r2 --identity <age-key-file> [--archive <name>] [--confirm]
#
# Without --confirm the run stops once the backup is open, which is enough to
# show that the key works and the archive is sound. With it, the containers
# holding the state volume are stopped, the state is replaced by what the
# archive holds, and the containers are started again.
#
# The module supplies the rest through the environment:
#
#   HERMES_STATE_VOLUME   podman volume holding the state
#   HERMES_RESTORE_UNITS  units to stop while the state is replaced
#   BACKUP_ENV_FILE       file holding the R2 credentials
#
# plus BACKUP_NAME and BACKUP_PREFIX, which `r2 restore` reads.
set -euo pipefail
umask 077

: "${HERMES_STATE_VOLUME:?}" "${HERMES_RESTORE_UNITS:?}" "${BACKUP_ENV_FILE:?}"

fail() {
	echo "hermes-restore-r2: $*" >&2
	exit 1
}

usage() {
	cat <<'USAGE'
Usage:
  hermes-restore-r2 --list
  hermes-restore-r2 --identity <age-key-file> [--archive <name>] [--confirm]

  --identity  age identity file the backups are encrypted to
  --archive   backup to restore, defaulting to the newest
  --confirm   replace the live state; without it the run stops after unpacking
  --list      print the backups held in R2 and exit
USAGE
}

identity=""
archive=""
confirm=false
list=false

while [ "$#" -gt 0 ]; do
	case "$1" in
	--identity)
		identity="${2:?--identity takes a file}"
		shift 2
		;;
	--archive)
		archive="${2:?--archive takes a backup name}"
		shift 2
		;;
	--confirm)
		confirm=true
		shift
		;;
	--list)
		list=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 1
		;;
	esac
done

# The credentials and the state volume are root's to read and write.
[ "$(id -u)" -eq 0 ] || fail "run this as root"

set -a
# shellcheck source=/dev/null
. "${BACKUP_ENV_FILE}"
set +a

if [ "${list}" = true ]; then
	exec r2 restore list
fi

[ -n "${identity}" ] || fail "the offline age key is needed: --identity <file>"

state="$(podman volume inspect --format '{{.Mountpoint}}' "${HERMES_STATE_VOLUME}")"

[ -d "${state}" ] || fail "the ${HERMES_STATE_VOLUME} volume has no directory at ${state}"

work="$(mktemp -d)"
# Hermes' bundled skills are materialised read-only, and the archive carries
# that, so give the tree owner-write back before removing it.
trap 'chmod -R u+w "${work}" 2>/dev/null || true; rm -rf "${work}"' EXIT

unpacked="${work}/state"

fetched="$(
	BACKUP_IDENTITY_FILE="${identity}" \
		BACKUP_ARCHIVE="${archive}" \
		BACKUP_RESTORE_DIR="${unpacked}" \
		r2 restore fetch
)"

if [ "${confirm}" != true ]; then
	echo "${fetched} opened cleanly: $(du -sh "${unpacked}" | cut -f1) in $(find "${unpacked}" -type f | wc -l) files"
	echo "re-run with --confirm to replace the contents of ${state}"
	exit 0
fi

read -r -a units <<<"${HERMES_RESTORE_UNITS}"
stopped=()

for unit in "${units[@]}"; do
	if systemctl is-active --quiet "${unit}"; then
		echo "stopping ${unit}"
		systemctl stop "${unit}"
		stopped+=("${unit}")
	fi
done

echo "replacing ${state} with ${fetched}"
rsync -a --numeric-ids --delete "${unpacked}/" "${state}/"

for unit in "${stopped[@]}"; do
	echo "starting ${unit}"
	systemctl start "${unit}"
done

echo "restored ${fetched} into ${HERMES_STATE_VOLUME}"
