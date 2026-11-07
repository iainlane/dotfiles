# shellcheck shell=bash

set -euo pipefail

if (($# > 1)) || [[ "${1:-}" != "" && "${1:-}" != "--force" ]]; then
	echo 'Usage: update-xrt [--force]' >&2
	exit 1
fi

root="$(git rev-parse --show-toplevel)"
version="$(gh api repos/amd/xdna-driver/tags --paginate | jq -ser '
  add | map(.name | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
  | sort_by(split(".") | map(tonumber)) | last
')"
gh api "repos/Xilinx/XRT/git/ref/tags/${version}" >/dev/null
current="$(nix eval --raw "${root}#packages.x86_64-linux.xrt.version")"

if [[ "${version}" == "${current}" && "${1:-}" != "--force" ]]; then
	echo "XRT is already on ${version}." >&2
	exit 0
fi

backup="$(mktemp -d)"
cp package.nix xdna.nix "${backup}/"
cleanup() {
	status="$?"
	if ((status != 0)); then
		cp "${backup}/package.nix" "${backup}/xdna.nix" "${root}/pkgs/xrt/"
	fi
	rm -rf "${backup}"
}
trap cleanup EXIT

cd "${root}"
preference="${version}"
if [[ "${version}" == "${current}" ]]; then
	preference=skip
fi
nix-update --flake --system x86_64-linux --version="${preference}" \
	--override-filename pkgs/xrt/package.nix xrt
nix-update --flake --system x86_64-linux --version=skip \
	--override-filename pkgs/xrt/xdna.nix xrt.xdna.plugin

echo "Updated XRT and its XDNA plugin to ${version}." >&2
