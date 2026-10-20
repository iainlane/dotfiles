#!/usr/bin/env bash
set -euo pipefail

backup_script="${1}"
export REAL_ZSTD="${2}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

export TEST_DIR="${test_dir}"
mkdir -p "${test_dir}"/{bin,source,restored,upload,scratch}
printf 'backup contents\n' >"${test_dir}/source/example"

stub() {
	printf '#!%s\n' "${BASH}" >"${test_dir}/bin/${1}"
	cat >>"${test_dir}/bin/${1}"
	chmod +x "${test_dir}/bin/${1}"
}

stub zstd <<'EOF'
set -euo pipefail
printf '%s\n' "$@" >"${TEST_DIR}/zstd.args"
exec "${REAL_ZSTD}" "$@"
EOF

stub rclone <<'EOF'
set -euo pipefail
case "${1}" in
copy) cp "${2}" "${TEST_DIR}/upload/archive.age" ;;
delete) ;;
*) exit 1 ;;
esac
EOF

age-keygen -o "${test_dir}/identity" 2>/dev/null
recipient="$(age-keygen -y "${test_dir}/identity")"

PATH="${test_dir}/bin:${PATH}" TMPDIR="${test_dir}/scratch" \
	BACKUP_NAME=example BACKUP_PREFIX=example \
	BACKUP_SOURCE="${test_dir}/source" BACKUP_AGE_RECIPIENT="${recipient}" \
	BACKUP_KEEP_DAYS=30 R2_BUCKET=example R2_ENDPOINT=https://example.invalid \
	R2_ACCESS_KEY_ID=example R2_SECRET_ACCESS_KEY=example \
	bash "${backup_script}" backup

printf '%s\n' -T1 -3 >"${test_dir}/expected.args"
diff -u "${test_dir}/expected.args" "${test_dir}/zstd.args"

age -d -i "${test_dir}/identity" "${test_dir}/upload/archive.age" |
	"${REAL_ZSTD}" -d |
	tar -xf - -C "${test_dir}/restored"
diff -ru "${test_dir}/source" "${test_dir}/restored"
