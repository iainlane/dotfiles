#!/usr/bin/env bash

set -euo pipefail

build_script="${1}"
common_script="${2}"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/scripts/lib" "${fixture}/bin"
cp "${build_script}" "${fixture}/scripts/build-iso.bash"
cp "${common_script}" "${fixture}/scripts/lib/just-common.bash"
export ISO_COMMAND_LOG="${fixture}/commands"
export PATH="${fixture}/bin:${PATH}"

cat >"${fixture}/bin/nix" <<'NIX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >>"${ISO_COMMAND_LOG}"
printf '\n' >>"${ISO_COMMAND_LOG}"
case "$1" in
eval)
	if [[ "$2" == --impure ]]; then
		printf '%s\n' "${ISO_BUILD_SYSTEM}"
	else
		printf 'x86_64-linux\n'
	fi
	;;
build)
	if [[ "$2" == --eval-store ]]; then
		[[ "${ISO_SCENARIO}" != contents-failure ]] || exit 7
		printf '[{"outputs":{"out":"/nix/store/fixture-contents"}}]\n'
	else
		[[ "${ISO_SCENARIO}" != assembly-failure ]] || exit 8
		if [[ "${ISO_SCENARIO}" != missing-image ]]; then
			mkdir -p result-target-iso/iso
			touch result-target-iso/iso/fixture.iso
		fi
	fi
	;;
run)
	cat >/dev/null
	printf '/nix/store/fixture-contents\n'
	;;
copy) [[ "${ISO_SCENARIO}" != copy-failure ]] || exit 9 ;;
*) exit 99 ;;
esac
NIX
chmod +x "${fixture}/bin/nix"

for build_system in aarch64-darwin aarch64-linux x86_64-linux; do
	for scenario in success contents-failure copy-failure assembly-failure missing-image; do
		export ISO_BUILD_SYSTEM="${build_system}"
		export ISO_SCENARIO="${scenario}"
		: >"${ISO_COMMAND_LOG}"
		rm -rf "${fixture}/result-target-iso"
		status=0
		bash "${fixture}/scripts/build-iso.bash" target >"${fixture}/output" 2>&1 || status=$?

		{
			printf '%s\0' eval --impure --expr builtins.currentSystem --raw
			printf '\n'
			printf '%s\0' eval '.#hosts.target.system' --raw
			printf '\n'
			printf '%s\0' build --eval-store auto --store ssh-ng://nixbuild-store --json --no-link '.#packages.x86_64-linux.target-iso-contents'
			printf '\n'
			if [[ "${scenario}" != contents-failure ]]; then
				printf '%s\0' run nixpkgs#jq -- -r '.[0].outputs.out'
				printf '\n'
				printf '%s\0' copy --from 'ssh-ng://nixbuild-store?trusted=1' /nix/store/fixture-contents
				printf '\n'
			fi
			case "${scenario}" in
			success | assembly-failure | missing-image)
				printf '%s\0' build ".#packages.${build_system}.target-iso" --out-link result-target-iso
				printf '\n'
				;;
			esac
		} >"${fixture}/expected-commands"

		expected_status=0
		case "${scenario}" in
		contents-failure) expected_status=7 ;;
		copy-failure) expected_status=9 ;;
		assembly-failure) expected_status=8 ;;
		missing-image) expected_status=1 ;;
		esac
		if [[ "${status}" != "${expected_status}" ]]; then
			cat "${fixture}/output" >&2
			printf '%s/%s: expected status %s, got %s\n' "${build_system}" "${scenario}" "${expected_status}" "${status}" >&2
			exit 1
		fi
		cmp "${fixture}/expected-commands" "${ISO_COMMAND_LOG}"
	done
done

printf 'ISO remote-contents and local-assembly checks passed.\n'
