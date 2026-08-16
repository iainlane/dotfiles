#!/usr/bin/env bash

set -euo pipefail

retry_script="${1}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir "${test_dir}/bin"

# The Nix build sandbox has no /usr/bin/env, so give each stub the running
# bash as its interpreter.
printf '#!%s\n' "${BASH}" >"${test_dir}/bin/nix"
cat >>"${test_dir}/bin/nix" <<'EOF'

set -euo pipefail

case "${FAKE_NIX_SCENARIO}" in
fail-once)
	if [[ ! -f "${FAKE_NIX_STATE}" ]]; then
		touch "${FAKE_NIX_STATE}"
		printf "error: Cannot build '/nix/store/example.drv'.\n" >&2
		exit 1
	fi

	printf 'build completed on retry\n'
	;;
always-fails)
	printf "error: Cannot build '/nix/store/example.drv'.\n" >&2
	exit 42
	;;
success)
	printf 'build completed\n'
	;;
*)
	exit 99
	;;
esac
EOF
chmod +x "${test_dir}/bin/nix"

printf '#!%s\n' "${BASH}" >"${test_dir}/bin/sleep"
cat >>"${test_dir}/bin/sleep" <<'EOF'
exit 0
EOF
chmod +x "${test_dir}/bin/sleep"

run_retry() {
	local scenario="${1}"
	shift

	PATH="${test_dir}/bin:${PATH}" \
		FAKE_NIX_SCENARIO="${scenario}" \
		FAKE_NIX_STATE="${test_dir}/state" \
		bash "${retry_script}" "$@"
}

output="$(run_retry fail-once build .#checks.x86_64-linux.example 2>&1)"
[[ "${output}" == *"Cannot build '/nix/store/example.drv'."* ]]
[[ "${output}" == *'attempt 1/3'* ]]
[[ "${output}" == *'build completed on retry'* ]]

rm "${test_dir}/state"
set +e
output="$(run_retry always-fails build .#checks.x86_64-linux.example 2>&1)"
status=$?
set -e

[[ "${status}" -eq 42 ]]
[[ "${output}" == *"Cannot build '/nix/store/example.drv'."* ]]
[[ "${output}" == *'attempt 1/3'* ]]
[[ "${output}" == *'attempt 2/3'* ]]

output="$(run_retry success flake check --all-systems --no-build 2>&1)"
[[ "${output}" == *'build completed'* ]]
[[ "${output}" != *'retrying'* ]]
