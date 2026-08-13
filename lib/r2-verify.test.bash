#!/usr/bin/env bash

set -euo pipefail

verify_script="${1}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir "${test_dir}/bin"

# The listing is whatever the case under test wrote. A path that is not there
# stands for a bucket rclone cannot read.
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
		bash "${verify_script}"
}

assert_fails() {
	local listing="${1}" expected="${2}" output status

	set +e
	output="$(run_verify "${listing}" 2>&1)"
	status=$?
	set -e

	[[ "${status}" -ne 0 ]]
	[[ "${output}" == *"${expected}"* ]]
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

output="$(run_verify healthy)"
[[ "${output}" == *'hermes-20260809T040000Z: 6000000 bytes, 2h old, 3 kept'* ]]

failures=(
	"stale|hermes-20260806T040000Z is 72h old, past the 48h threshold"
	"small|hermes-20260809T040000Z is 1024 bytes, under the 65536 byte floor"
	"empty|no hermes backups under"
	"absent|cannot list"
)

for scenario in "${failures[@]}"; do
	assert_fails "${scenario%%|*}" "${scenario#*|}"
done

min_count=5 assert_fails healthy "holds 3 backups, expected at least 5"
