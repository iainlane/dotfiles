#!/usr/bin/env bash

set -euo pipefail

source_root="${1}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir -p "${test_dir}/bin" "${test_dir}/scripts" "${test_dir}/lib/nix"
cp "${source_root}/justfile" "${test_dir}/justfile"
cp "${source_root}/scripts/check-evaluation.bash" "${source_root}/scripts/evaluation-shards.nix" "${test_dir}/scripts/"
cp "${source_root}/lib/nix/evaluation.conf" "${test_dir}/lib/nix/"

# The Linux build sandbox has no /usr/bin/env.
sed -i "1s|^#!.*|#!${BASH}|" "${test_dir}/scripts/check-evaluation.bash"

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
	[[ "${*: -3}" == '--option allow-import-from-derivation false' ]]
	if [[ "${3}" != .#.cupboardOutputs ]]; then
		printf 'evaluate %s\n' "${3}" >>"${CHECK_TEST_LOG}"
		exit 0
	fi
	case "${5}" in
	*'shard = null;'*)
		printf 'inventory\n' >>"${CHECK_TEST_LOG}"
		printf 'system-aarch64-linux\taarch64-linux/checks-first\n'
		if [[ "${CHECK_TEST_MODE:-}" == duplicate ]]; then
			printf 'system-aarch64-linux\taarch64-linux/checks-first\n'
		fi
		printf 'system-aarch64-linux\taarch64-linux/checks-second\n'
		printf 'x86_64-linux-packages\tx86_64-linux/packages\n'
		;;
	*'shard = "system-aarch64-linux";'*)
		printf 'shard system-aarch64-linux\n' >>"${CHECK_TEST_LOG}"
		[[ "${CHECK_TEST_MODE:-}" != failed-shard ]] || exit 17
		printf 'system-aarch64-linux\taarch64-linux/checks-first\t/nix/store/first.drv\n'
		if [[ "${CHECK_TEST_MODE:-}" != missing-target ]]; then
			printf 'system-aarch64-linux\taarch64-linux/checks-second\t/nix/store/second.drv\n'
		fi
		;;
	*'shard = "x86_64-linux-packages";'*)
		printf 'shard x86_64-linux-packages\n' >>"${CHECK_TEST_LOG}"
		printf 'x86_64-linux-packages\tx86_64-linux/packages\t/nix/store/packages.drv\n'
		;;
	*) exit 2 ;;
	esac
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
expected='inventory
shard system-aarch64-linux
shard x86_64-linux-packages
evaluate .#.checks
flake check --keep-going --option allow-import-from-derivation false'

if [[ "${actual}" != "${expected}" ]]; then
	printf 'Expected check commands:\n%s\nActual check commands:\n%s\n' "${expected}" "${actual}" >&2
	exit 1
fi

printf 'All systems are evaluated; only native checks are built.\n'

export PATH="${test_dir}/bin:${PATH}"
export CHECK_TEST_LOG="${test_dir}/commands"
manifest="$(bash "${test_dir}/scripts/check-evaluation.bash" --manifest)"
expected="$(printf '%s\t%s\n' \
	aarch64-linux/checks-first /nix/store/first.drv \
	aarch64-linux/checks-second /nix/store/second.drv \
	x86_64-linux/packages /nix/store/packages.drv)"
[[ "${manifest}" == "${expected}" ]]

for failure in duplicate failed-shard missing-target; do
	if CHECK_TEST_MODE="${failure}" bash "${test_dir}/scripts/check-evaluation.bash" >"${test_dir}/output"; then
		printf 'The gate accepted fixture failure: %s\n' "${failure}" >&2
		exit 1
	fi
	[[ ! -s "${test_dir}/output" ]]
done

printf 'A complete manifest passes; duplicate targets, failed shards and incomplete shards are rejected.\n'
