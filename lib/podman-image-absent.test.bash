#!/usr/bin/env bash

set -euo pipefail

script="${1}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir "${test_dir}/bin"

# The stub answers `podman image exists` from FAKE_PRESENT_IMAGES, one
# reference per line, and records every invocation so a test can check
# the reference the script asked about.
#
# The Nix build sandbox has no /usr/bin/env, so give the stub the running
# bash as its interpreter.
printf '#!%s\n' "${BASH}" >"${test_dir}/bin/podman"
cat >>"${test_dir}/bin/podman" <<'EOF2'

set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_PODMAN_CALLS}"

[ "${1}" = image ] && [ "${2}" = exists ] || exit 125

grep -qxF "${3}" "${FAKE_PRESENT_IMAGES}"
EOF2
chmod +x "${test_dir}/bin/podman"

run_guard() {
	PATH="${test_dir}/bin:${PATH}" \
		FAKE_PRESENT_IMAGES="${test_dir}/present" \
		FAKE_PODMAN_CALLS="${test_dir}/calls" \
		bash "${script}" "${1}"
}

report_failure() {
	local scenario="${1}" expected="${2}" actual="${3}"

	{
		echo "scenario: ${scenario}"
		echo "expected: ${expected}"
		echo "actual:   ${actual}"
	} >&2

	exit 1
}

# Each case is: scenario, images present in local storage, reference asked
# about, expected exit status. The expected podman call is the same for
# every case.
cases=(
	"the image is absent so the pull goes ahead|localhost/other:tag|localhost/app:tag|0"
	"the image is present so the pull is skipped|localhost/app:tag|localhost/app:tag|1"
	"nothing is in local storage so the pull goes ahead||localhost/app:tag|0"
)

for case in "${cases[@]}"; do
	IFS='|' read -r scenario present reference expected_status <<<"${case}"

	printf '%s\n' "${present}" >"${test_dir}/present"
	: >"${test_dir}/calls"

	status=0
	run_guard "${reference}" || status=$?

	actual="status=${status} calls=$(tr '\n' ';' <"${test_dir}/calls")"
	expected="status=${expected_status} calls=image exists ${reference};"

	[ "${actual}" = "${expected}" ] || report_failure "${scenario}" "${expected}" "${actual}"
done

echo "all podman-image-absent scenarios passed"
