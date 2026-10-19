# shellcheck shell=bash

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "${root}"
package=pkgs/herdr-disp-model/package.nix
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

nix-update --flake --version=branch=main --override-filename "${package}" herdr-disp-model
source="$(nix build --no-link --print-out-paths .#herdr-disp-model.src)"
current="$(nix eval --raw .#herdr-disp-model.version)"
manifest_version="$(nix eval --raw --impure --expr "(builtins.fromTOML (builtins.readFile ${source}/herdr-plugin.toml)).version")"
version="${manifest_version}-unstable-${current##*-unstable-}"

jq --raw-input --slurp --join-output \
	--arg old "version = \"${current}\";" \
	--arg new "version = \"${version}\";" \
	--from-file pkgs/build-support/replace-once.jq "${package}" >"${backup}/updated.nix"
cat "${backup}/updated.nix" >"${package}"
