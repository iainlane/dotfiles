# shellcheck shell=bash
#
# Dump the AgentsView database and hand the result to `r2 backup`. Driven
# entirely by the environment so it stays a plain, checkable shell script:
#
#   AGENTSVIEW_CONTAINER   container running Postgres
#   AGENTSVIEW_PG_DUMP     pg_dump inside that container
#   AGENTSVIEW_DATABASE    database to dump
#   AGENTSVIEW_SUPERUSER   role to connect as
#   AGENTSVIEW_SOCKET_DIR  directory holding the Postgres socket
#
# plus everything `r2 backup` reads.
#
# Postgres keeps serving while this runs. `pg_dump` reads inside a single
# repeatable-read transaction, so the dump shows the database as it was when
# the dump began, and the machines carry on pushing throughout.
#
# This dumps the one database. The roles belong to the cluster, and the roles
# unit rebuilds them from the secrets repository at every start.
set -euo pipefail
umask 077

: "${AGENTSVIEW_CONTAINER:?}" "${AGENTSVIEW_PG_DUMP:?}" "${AGENTSVIEW_DATABASE:?}"
: "${AGENTSVIEW_SUPERUSER:?}" "${AGENTSVIEW_SOCKET_DIR:?}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

snapshot="${work}/snapshot"
mkdir -p "${snapshot}"

dump="${snapshot}/${AGENTSVIEW_DATABASE}.dump"

# The custom format lets a restore take one table at a time and in parallel.
# `r2 backup` compresses with zstd, thus pg_dump does none of its own.
podman exec "${AGENTSVIEW_CONTAINER}" \
	"${AGENTSVIEW_PG_DUMP}" \
	--format=custom \
	--compress=0 \
	--host="${AGENTSVIEW_SOCKET_DIR}" \
	--username="${AGENTSVIEW_SUPERUSER}" \
	"${AGENTSVIEW_DATABASE}" >"${dump}"

# A failing `pg_dump` already stops this script. This catches the other case:
# a clean exit that wrote nothing, which would upload an empty archive.
[ -s "${dump}" ] || {
	echo "the dump of ${AGENTSVIEW_DATABASE} is empty" >&2
	exit 1
}

echo "dumped ${AGENTSVIEW_DATABASE}: $(stat -c %s "${dump}") bytes"

BACKUP_SOURCE="${snapshot}" exec r2 backup
