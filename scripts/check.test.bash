#!/usr/bin/env bash

set -euo pipefail

source_root="${1}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir -p "${test_dir}/bin" "${test_dir}/scripts" "${test_dir}/lib/nix"
cp "${source_root}/justfile" "${test_dir}/justfile"
cp "${source_root}/scripts/check-evaluation.bash" "${test_dir}/scripts/"
cp "${source_root}/lib/nix/evaluation.conf" "${test_dir}/lib/nix/"

printf '#!%s\n' "${BASH}" >"${test_dir}/bin/gh"
printf 'exit 1\n' >>"${test_dir}/bin/gh"

printf '#!%s\n' "${BASH}" >"${test_dir}/bin/nix"
cat >>"${test_dir}/bin/nix" <<'EOF'
set -euo pipefail

if [[ "${1}" == eval && "${3}" == .#.username ]]; then
	printf 'fixture\n'
	exit 0
fi

[[ "${NIX_CONFIG}" == *'allow-import-from-derivation = false'* ]]

if [[ "${1}" == eval ]]; then
	printf 'evaluate %s\n' "${3}" >>"${CHECK_TEST_LOG}"
	exit 0
fi

printf '%s\n' "$*" >>"${CHECK_TEST_LOG}"
EOF
chmod +x "${test_dir}/bin/gh" "${test_dir}/bin/nix"

PATH="${test_dir}/bin:${PATH}" \
	CHECK_TEST_LOG="${test_dir}/commands" \
	just --justfile "${test_dir}/justfile" --working-directory "${test_dir}" \
	check --keep-going

actual="$(<"${test_dir}/commands")"
expected='evaluate .#.cupboardOutputs
evaluate .#.checks
flake check --keep-going --option allow-import-from-derivation false'

if [[ "${actual}" != "${expected}" ]]; then
	printf 'Expected check commands:\n%s\nActual check commands:\n%s\n' "${expected}" "${actual}" >&2
	exit 1
fi

printf 'All systems are evaluated; only native checks are built.\n'
