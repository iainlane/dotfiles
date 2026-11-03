# shellcheck shell=bash

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "${root}"
package=pkgs/rea/package.nix
backup="$(mktemp -d)"
cp "${package}" "${backup}/package.nix"
cleanup() {
	status="$?"
	if ((status != 0)); then
		cp "${backup}/package.nix" "${package}"
	fi
	rm -rf "${backup}"
}
trap cleanup EXIT

nix-update --flake --version=stable --use-github-releases \
	--version-regex='^rea-agents-([0-9]+\.[0-9]+\.[0-9]+)$' \
	--override-filename "${package}" rea
