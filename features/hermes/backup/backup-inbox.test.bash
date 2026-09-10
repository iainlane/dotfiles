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
mkdir -p "${test_dir}/bin" "${test_dir}/state/.hermes/plugin-data/${data_namespace}"

cat >"${test_dir}/bin/r2" <<EOF
#!${BASH}
set -euo pipefail
test "\${1}" = backup
db="\${BACKUP_SOURCE}/.hermes/plugin-data/${data_namespace}/inbox.sqlite3"
test -f "\${db}"
test ! -e "\${db}-wal"
test "\$(sqlite3 "\${db}" 'select group_concat(value) from evidence')" = committed
EOF
chmod +x "${test_dir}/bin/r2"

db="${test_dir}/state/.hermes/plugin-data/${data_namespace}/inbox.sqlite3"
DB="${db}" READY="${test_dir}/ready" STOP="${test_dir}/stop" python3 <<'PY' &
import os
import sqlite3
import time

connection = sqlite3.connect(os.environ["DB"])
connection.execute("pragma journal_mode=wal")
connection.execute("pragma wal_autocheckpoint=0")
connection.execute("create table evidence(value text)")
connection.execute("insert into evidence values ('committed')")
connection.commit()
connection.execute("insert into evidence values ('uncommitted')")
open(os.environ["READY"], "w").close()
while not os.path.exists(os.environ["STOP"]):
    time.sleep(0.01)
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
