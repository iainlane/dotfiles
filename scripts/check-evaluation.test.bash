#!/usr/bin/env bash

set -euo pipefail

evaluation_script="${1}"
fixture="${2}"
test_dir="$(mktemp -d)"
test_dir="$(cd "${test_dir}" && pwd -P)"
trap 'rm -rf "${test_dir}"' EXIT

store="local?store=${test_dir}/store&state=${test_dir}/state&log=${test_dir}/log"
options=(
	--store "${store}"
	--impure
	--option experimental-features nix-command
	--option build-users-group ''
	--option sandbox false
	--option substituters ''
	--option builders ''
	--option allow-import-from-derivation true
)

export NIX_CONFIG='allow-import-from-derivation = true'

output="$(bash "${evaluation_script}" "${options[@]}" --raw --file "${fixture}" sourceRead)"
[[ "${output}" == 'evaluation fixture' ]]

reject_ifd() {
	local output
	if output="$(bash "${evaluation_script}" "${options[@]}" --raw --file "${fixture}" derivationRead 2>&1)"; then
		printf 'Evaluation must reject import-from-derivation, but succeeded:\n%s\n' "${output}" >&2
		exit 1
	fi
}

reject_ifd

output="$(nix eval "${options[@]}" --raw --file "${fixture}" derivationRead)"
[[ "${output}" == 'evaluation fixture' ]]
reject_ifd

printf 'Source reads pass; uncached and cached derivation reads are rejected.\n'
