#!/usr/bin/env bash

set -euo pipefail

refresh_script="${1}"
common_script="${2}"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

mkdir -p "${fixture}/scripts/lib" "${fixture}/bin" "${fixture}/project with spaces"
cp "${refresh_script}" "${fixture}/scripts/refresh-direnvs.bash"
cp "${common_script}" "${fixture}/scripts/lib/just-common.bash"
export PROJECT_DIRECTORIES_FILE="${fixture}/directories"
export REFRESH_LOG="${fixture}/calls"
export XDG_STATE_HOME="${fixture}/state"
export PATH="${fixture}/bin:${PATH}"
export USER=wrong-user
export NIX_DIRENV_DID_FALLBACK=1

# The Nix build sandbox has no /usr/bin/env, so give the stubs the running
# bash as their interpreter.
stub() {
	printf '#!%s\n' "${BASH}" >"${fixture}/bin/${1}"
	cat >>"${fixture}/bin/${1}"
	chmod +x "${fixture}/bin/${1}"
}

stub hostname <<'HOSTNAME'
printf 'fixture-host\n'
HOSTNAME

stub nix <<'NIX'
set -euo pipefail
[[ "$1" == eval ]] || exit 99
if [[ "$*" == *".#username"* ]]; then
	printf 'fixture-user'
	exit 0
fi
[[ "${REFRESH_MODE}" != eval-failure ]] || exit 7
[[ "$*" == *'.#homeResults."fixture-user@fixture-host"'* ]] || {
	echo "refresh used the wrong Home Manager identity: $*" >&2
	exit 8
}
cat "${PROJECT_DIRECTORIES_FILE}"
NIX

stub direnv <<'DIRENV'
set -euo pipefail
[[ "$1" == exec ]] || exit 99
printf '%s\n' "$2" >>"${REFRESH_LOG}"
shift 2
case "${REFRESH_MODE}" in
fallback) export NIX_DIRENV_DID_FALLBACK=1 ;;
failure) exit 7 ;;
esac
exec "$@"
DIRENV

for scenario in fallback failure missing-envrc eval-failure refresh after-switch empty; do
	export REFRESH_MODE="${scenario}"
	roots="${XDG_STATE_HOME}/nix/direnv-shells"
	mkdir -p "${roots}"
	touch "${roots}/shell"
	printf '%s\n' "${fixture}/project with spaces" >"${PROJECT_DIRECTORIES_FILE}"
	touch "${fixture}/project with spaces/.envrc"
	: >"${REFRESH_LOG}"

	arguments=(--after-switch)
	expected_status=1
	expected_root=present
	case "${scenario}" in
	missing-envrc) rm "${fixture}/project with spaces/.envrc" ;;
	eval-failure) expected_status=7 ;;
	refresh)
		arguments=()
		expected_status=0
		;;
	after-switch)
		expected_status=0
		expected_root=absent
		;;
	empty)
		: >"${PROJECT_DIRECTORIES_FILE}"
		expected_status=0
		expected_root=absent
		;;
	esac

	status=0
	bash "${fixture}/scripts/refresh-direnvs.bash" "${arguments[@]}" >"${fixture}/output" 2>&1 || status=$?
	actual_root=absent
	[[ ! -e "${roots}/shell" ]] || actual_root=present
	actual="${status}:${actual_root}"
	expected="${expected_status}:${expected_root}"
	if [[ "${actual}" != "${expected}" ]]; then
		cat "${fixture}/output" >&2
		printf '%s: expected %s, got %s\n' "${scenario}" "${expected}" "${actual}" >&2
		exit 1
	fi

	case "${scenario}" in
	missing-envrc | eval-failure | empty) : >"${fixture}/expected-calls" ;;
	*) printf '%s\n' "${fixture}/project with spaces" >"${fixture}/expected-calls" ;;
	esac
	cmp "${fixture}/expected-calls" "${REFRESH_LOG}"
done

printf 'Project cache refresh and legacy-root migration checks passed.\n'
