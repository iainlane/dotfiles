#!/usr/bin/env bash
set -euo pipefail

backup_script="${1}"
export REAL_PV="${2}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

export TEST_DIR="${test_dir}"
mkdir -p "${test_dir}/bin" "${test_dir}/scratch"
printf 'PGDMP\0example\n' >"${test_dir}/dump"

stub() {
	printf '#!%s\n' "${BASH}" >"${test_dir}/bin/${1}"
	cat >>"${test_dir}/bin/${1}"
	chmod +x "${test_dir}/bin/${1}"
}

stub podman <<'EOF'
set -euo pipefail
printf '%s\n' "$@" >"${TEST_DIR}/podman.args"
if [ "${SCENARIO}" = empty ]; then exit 0; fi
cat "${TEST_DIR}/dump"
if [ "${SCENARIO}" = dump-failure ]; then exit 1; fi
EOF

stub pv <<'EOF'
set -euo pipefail
printf '%s\n' "$@" >"${TEST_DIR}/pv.args"
if [ "${SCENARIO}" = pacing-failure ]; then exit 1; fi
exec "${REAL_PV}" "$@"
EOF

stub r2 <<'EOF'
set -euo pipefail
printf '%s\n' "$@" >"${TEST_DIR}/r2.args"
cp "${BACKUP_SOURCE}/agentsview.dump" "${TEST_DIR}/uploaded.dump"
EOF

for scenario in success empty dump-failure pacing-failure; do
	rm -f "${test_dir}"/{podman.args,pv.args,r2.args,uploaded.dump}
	status=0
	PATH="${test_dir}/bin:${PATH}" TMPDIR="${test_dir}/scratch" \
		SCENARIO="${scenario}" AGENTSVIEW_CONTAINER=agentsview-db \
		AGENTSVIEW_PG_DUMP=/bin/pg_dump AGENTSVIEW_DATABASE=agentsview \
		AGENTSVIEW_SUPERUSER=postgres AGENTSVIEW_SOCKET_DIR=/run/postgresql \
		AGENTSVIEW_DUMP_RATE_LIMIT=10485760 \
		bash "${backup_script}" >"${test_dir}/output" 2>&1 || status=$?

	if [ "${scenario}" != success ]; then
		if [ "${status}" -eq 0 ] || [ -e "${test_dir}/uploaded.dump" ]; then
			echo "${scenario}: expected failure without upload" >&2
			exit 1
		fi
		continue
	fi

	if [ "${status}" -ne 0 ]; then
		cat "${test_dir}/output" >&2
		exit 1
	fi

	printf '%s\n' exec agentsview-db /bin/pg_dump --format=custom --compress=0 \
		--host=/run/postgresql --username=postgres agentsview >"${test_dir}/expected.args"
	diff -u "${test_dir}/expected.args" "${test_dir}/podman.args"
	printf '%s\n' --quiet --rate-limit 10485760 >"${test_dir}/expected.args"
	diff -u "${test_dir}/expected.args" "${test_dir}/pv.args"
	printf '%s\n' backup >"${test_dir}/expected.args"
	diff -u "${test_dir}/expected.args" "${test_dir}/r2.args"
	diff -u "${test_dir}/dump" "${test_dir}/uploaded.dump"
done
