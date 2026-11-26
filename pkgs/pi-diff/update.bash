# shellcheck shell=bash

set -euo pipefail

if [[ "$#" -gt 1 || ("$#" -eq 1 && "$1" != --refresh) ]]; then
	printf 'Usage: update-pi-diff [--refresh]\n' >&2
	exit 1
fi

repo="$(git rev-parse --show-toplevel)"
attr="${LOCAL_PACKAGES_ATTR}.pi-diff"
lockfile=npm-deps/package-lock.json
pi=@earendil-works/pi-coding-agent
ai=@earendil-works/pi-ai
tui=@earendil-works/pi-tui

in_repo() (
	cd "${repo}"
	"$@"
)

version="$(in_repo nix eval --raw ".#${LOCAL_PACKAGES_ATTR}.pi.version" --option allow-import-from-derivation false)"
scratch="$(mktemp -d "${PWD}/npm-deps/.pi-diff-lock.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT

touch "${scratch}/npmrc"
export npm_config_cache="${scratch}/npm-cache"
export npm_config_userconfig="${scratch}/npmrc"
export npm_config_globalconfig=/dev/null
export npm_config_registry=https://registry.npmjs.org/

dependencies="$(cd "${scratch}" && npm view "${pi}@${version}" dependencies --json)"
ai_version="$(jq -er --arg name "${ai}" '.[$name] | strings | select(length > 0)' <<<"${dependencies}")"
tui_version="$(jq -er --arg name "${tui}" '.[$name] | strings | select(length > 0)' <<<"${dependencies}")"

source_lock="${lockfile}"
if [[ "$#" -eq 0 ]]; then
	in_repo nix-update --flake --override-filename pkgs/pi-diff/package.nix \
		--version=branch=pi-integration-fixes "${attr}" >&2
	source="$(in_repo nix build --no-link --print-out-paths ".#${attr}.src")"
	source_lock="${source}/package-lock.json"
fi

install -m 0644 "${source_lock}" "${scratch}/package-lock.json"
jq -e '.packages[""] | objects' "${source_lock}" >"${scratch}/package.json"
(
	cd "${scratch}"
	npm install --package-lock-only --ignore-scripts --no-audit --no-fund --save-dev --save-exact \
		"${pi}@${version}" "${ai}@${ai_version}" "${tui}@${tui_version}" >&2
)
jq --tab -e . "${scratch}/package-lock.json" >"${scratch}/updated-lock.json"
mv "${scratch}/updated-lock.json" "${lockfile}"
