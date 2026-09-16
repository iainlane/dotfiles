#!/usr/bin/env bash

set -euo pipefail

backup_script="${1}"
test_dir="$(mktemp -d)"
writer_pid=""
cleanup() {
	if [ -n "${writer_pid}" ]; then
		kill "${writer_pid}" 2>/dev/null || true
	fi
	rm -rf "${test_dir}"
}
trap cleanup EXIT

data_namespace="agent-plugin-hermes-inbox-1234abcd"

# Every SQLite database the agent keeps open while the backup runs, relative
# to the state directory. A writer holds each one open with an uncommitted
# row, so a copy not taken through the backup API shows up as a missing file,
# a stray -wal, or the uncommitted row.
databases=(
	.hermes/state.db
	.hermes/memory_store.db
	.hermes/kanban.db
	.hermes/shared-state.db
	.hermes/cron/deliveries.db
	".hermes/plugin-data/${data_namespace}/inbox.sqlite3"
)

mkdir -p "${test_dir}/bin"

for db in "${databases[@]}"; do
	mkdir -p "$(dirname "${test_dir}/state/${db}")"
done

cat >"${test_dir}/bin/r2" <<EOF
#!${BASH}
set -euo pipefail
test "\${1}" = backup
status=0
for db in ${databases[*]@Q}; do
	path="\${BACKUP_SOURCE}/\${db}"
	if [ ! -f "\${path}" ]; then
		echo "\${db}: missing from the snapshot" >&2
		status=1
	elif [ -e "\${path}-wal" ]; then
		echo "\${db}: copied live, -wal alongside" >&2
		status=1
	elif [ "\$(sqlite3 "\${path}" 'select group_concat(value) from evidence')" != committed ]; then
		echo "\${db}: uncommitted row in the snapshot" >&2
		status=1
	fi
done
exit "\${status}"
EOF
chmod +x "${test_dir}/bin/r2"

DBS="$(printf '%s\n' "${databases[@]/#/${test_dir}/state/}")" \
READY="${test_dir}/ready" STOP="${test_dir}/stop" python3 <<'PY' &
import os
import sqlite3
import time

connections = []
for path in os.environ["DBS"].splitlines():
    connection = sqlite3.connect(path)
    connection.execute("pragma journal_mode=wal")
    connection.execute("pragma wal_autocheckpoint=0")
    connection.execute("create table evidence(value text)")
    connection.execute("insert into evidence values ('committed')")
    connection.commit()
    connection.execute("insert into evidence values ('uncommitted')")
    connections.append(connection)
open(os.environ["READY"], "w").close()
while not os.path.exists(os.environ["STOP"]):
    time.sleep(0.01)
for connection in connections:
    connection.close()
PY
writer_pid=$!

while [ ! -f "${test_dir}/ready" ]; do
	sleep 0.01
done

PATH="${test_dir}/bin:${PATH}" \
	HERMES_STATE_DIR="${test_dir}/state" \
	bash "${backup_script}"

touch "${test_dir}/stop"
wait "${writer_pid}"
writer_pid=""
