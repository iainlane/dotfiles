#!/usr/bin/env bash

set -euo pipefail

r2_script="${1}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir "${test_dir}/bin"

# The listing is whatever the case under test wrote. A path that is not there
# stands for a bucket rclone cannot read.
#
# The Nix build sandbox has no /usr/bin/env, so give the stub the running
# bash as its interpreter.
printf '#!%s\n' "${BASH}" >"${test_dir}/bin/rclone"
cat >>"${test_dir}/bin/rclone" <<'EOF'

set -euo pipefail

cat "${FAKE_RCLONE_LISTING}"
EOF
chmod +x "${test_dir}/bin/rclone"

hours_ago() {
	date -u -d "-${1} hours" +%Y-%m-%dT%H:%M:%SZ
}

entry() {
	printf '{"Name":"%s","Size":%s,"ModTime":"%s","IsDir":false}' "${1}" "${2}" "$(hours_ago "${3}")"
}

run_verify() {
	PATH="${test_dir}/bin:${PATH}" \
		FAKE_RCLONE_LISTING="${test_dir}/${1}.json" \
		BACKUP_NAME=hermes \
		BACKUP_PREFIX=hermes \
		BACKUP_MAX_AGE_HOURS=48 \
		BACKUP_MIN_SIZE=65536 \
		BACKUP_MIN_COUNT="${min_count:-1}" \
		R2_BUCKET=bucket \
		R2_ENDPOINT=https://example.invalid \
		R2_ACCESS_KEY_ID=key \
		R2_SECRET_ACCESS_KEY=secret \
		bash "${r2_script}" verify
}

report_failure() {
	local scenario="${1}" expected="${2}" status="${3}" output="${4}"

	{
		echo "scenario: ${scenario}"
		echo "expected output to contain: ${expected}"
		echo "status: ${status}"
		echo "output:"
		echo "${output}"
	} >&2

	exit 1
}

# Runs one scenario and checks the exit status and the output against what the
# scenario expects. `expected_status` is `zero` for a listing verify accepts
# and `nonzero` for one it has to reject.
assert_verify() {
	local scenario="${1}" expected_status="${2}" expected="${3}" output status

	set +e
	output="$(run_verify "${scenario}" 2>&1)"
	status=$?
	set -e

	case "${expected_status}" in
	zero)
		[[ "${status}" -eq 0 ]] ||
			report_failure "${scenario}" "${expected}" "${status}" "${output}"
		;;
	nonzero)
		[[ "${status}" -ne 0 ]] ||
			report_failure "${scenario}" "${expected}" "${status}" "${output}"
		;;
	esac

	[[ "${output}" == *"${expected}"* ]] ||
		report_failure "${scenario}" "${expected}" "${status}" "${output}"
}

# Out of listing order, so the newest has to be found by name.
cat >"${test_dir}/healthy.json" <<EOF
[
	$(entry hermes-20260807T040000Z 5000000 50),
	$(entry hermes-20260809T040000Z 6000000 2),
	$(entry hermes-20260808T040000Z 5500000 26)
]
EOF

cat >"${test_dir}/stale.json" <<EOF
[$(entry hermes-20260806T040000Z 6000000 72)]
EOF

cat >"${test_dir}/small.json" <<EOF
[$(entry hermes-20260809T040000Z 1024 2)]
EOF

printf '[]\n' >"${test_dir}/empty.json"

scenarios=(
	"healthy|zero|hermes-20260809T040000Z: 6000000 bytes, 2h old, 3 kept"
	"stale|nonzero|hermes-20260806T040000Z is 72h old, past the 48h threshold"
	"small|nonzero|hermes-20260809T040000Z is 1024 bytes, under the 65536 byte threshold"
	"empty|nonzero|no hermes backups under"
	"absent|nonzero|cannot list"
)

for scenario in "${scenarios[@]}"; do
	IFS='|' read -r name expected_status expected <<<"${scenario}"
	assert_verify "${name}" "${expected_status}" "${expected}"
done

min_count=5 assert_verify healthy nonzero "contains 3 backups, expected at least 5"
