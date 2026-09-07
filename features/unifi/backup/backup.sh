# shellcheck shell=bash
#
# Ask the controller for a backup of itself, download it, and hand the result
# to `r2 backup`.
#
#   UNIFI_URL              base URL of the controller's web UI
#   UNIFI_SITE             site whose Network application takes the backup
#   UNIFI_STATISTICS_DAYS  days of statistics to include: 0 for the settings
#                          alone, -1 for the whole history
#   UNIFI_API_KEY          an administrator's API key
#
# plus everything `r2 backup` reads.
#
# The controller keeps its configuration in mongodb, and its backup command
# writes a consistent copy while the controller keeps running. The result is
# a `.unf` file, the same one the web UI's "Download Backup" produces, and the
# web UI's restore page is what reads it back.
set -euo pipefail
umask 077

: "${UNIFI_URL:?}" "${UNIFI_SITE:?}" "${UNIFI_STATISTICS_DAYS:?}" "${UNIFI_API_KEY:?}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

snapshot="${work}/snapshot"
mkdir -p "${snapshot}"

# Command-line arguments are visible to every user in the process list, so
# the key reaches curl as a config on stdin instead. The controller serves a
# certificate it issued itself, which curl cannot verify, so verification is
# off; the request goes to this host's own LAN address and never leaves it.
request() {
	printf 'header = "X-API-KEY: %s"\n' "${UNIFI_API_KEY}" |
		curl --config - --silent --show-error --fail --insecure "$@"
}

# The command answers with the path of the file it wrote, relative to the
# Network application, which UniFi OS serves under /proxy/network.
path="$(
	request \
		--request POST \
		--header 'Content-Type: application/json' \
		--data "{\"cmd\":\"backup\",\"days\":${UNIFI_STATISTICS_DAYS}}" \
		"${UNIFI_URL}/proxy/network/api/s/${UNIFI_SITE}/cmd/backup" |
		jq --raw-output '.data[0].url // empty'
)"

[ -n "${path}" ] || {
	echo "the backup command returned no backup URL" >&2
	exit 1
}

file="${snapshot}/${path##*/}"

request --output "${file}" "${UNIFI_URL}/proxy/network${path}"

# A failing download already stops this script. Reject a successful download
# with an empty body, so an empty archive is never uploaded as a backup.
[ -s "${file}" ] || {
	echo "${file##*/} is empty" >&2
	exit 1
}

echo "downloaded ${file##*/}: $(stat -c %s "${file}") bytes"

BACKUP_SOURCE="${snapshot}" exec r2 backup
