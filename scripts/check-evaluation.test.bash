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

shard_expression="$(<"${evaluation_script%/*}/evaluation-shards.nix")"
evaluate() {
	bash "${evaluation_script}" "${options[@]}" --raw --file "${fixture}" "$1" \
		--apply "(${shard_expression}) { shard = $2; }"
}

inventory="$(evaluate targets null)"
expected="$(
	printf '%s\t%s\n' \
		system-aarch64-darwin aarch64-darwin/darwin-host \
		system-aarch64-linux aarch64-linux/checks-example
	for ((i = 0; i < 48; i++)); do
		printf 'x86_64-linux-checks-0\tx86_64-linux/checks-%s\n' "${i}"
	done
	printf '%s\t%s\n' \
		x86_64-linux-checks-48 x86_64-linux/checks-48 \
		x86_64-linux-deploy x86_64-linux/checks-deploy-activate \
		x86_64-linux-other-slow x86_64-linux/slow-checks-another \
		x86_64-linux-packages x86_64-linux/packages \
		x86_64-linux-podman x86_64-linux/slow-checks-podman-podman-example \
		x86_64-linux-podman-oci x86_64-linux/slow-checks-podman-oci-containers-example
)"
if [[ "${inventory}" != "${expected}" ]]; then
	printf 'Expected inventory:\n%s\nActual inventory:\n%s\n' "${expected}" "${inventory}" >&2
	exit 1
fi

[[ "$(evaluate ifdTarget null)" == "$(printf 'x86_64-linux-checks-0\tx86_64-linux/checks-ifd')" ]]
if output="$(evaluate ifdTarget '"x86_64-linux-checks-0"' 2>&1)"; then
	printf 'A shard accepted cached import-from-derivation:\n%s\n' "${output}" >&2
	exit 1
fi
[[ "${output}" == *'allow-import-from-derivation'* ]]

printf 'The inventory selects the expected shards without forcing derivation paths.\n'
