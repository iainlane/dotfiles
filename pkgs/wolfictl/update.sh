#!/usr/bin/env nix
#! nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#nix nixpkgs#wget --command bash
# shellcheck shell=bash

# Update wolfictl to the latest version.
# Reads the latest GitHub release tag, then downloads and hashes the release
# binary for every platform.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck source-path=SCRIPTDIR source=../_lib/prefetch.sh
source ../_lib/prefetch.sh

REPO="wolfi-dev/wolfictl"

# Nix system → goreleaser os_arch suffix.
declare -A PLATFORMS=(
	["x86_64-linux"]=linux_amd64
	["aarch64-linux"]=linux_arm64
	["x86_64-darwin"]=darwin_amd64
	["aarch64-darwin"]=darwin_arm64
)

echo "Fetching latest version..." >&2
tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | jq -r .tag_name)"
version="${tag#v}"
echo "Latest version: ${version}" >&2

pairs=()
for system in "${!PLATFORMS[@]}"; do
	suffix="${PLATFORMS[${system}]}"
	pairs+=("${system}=https://github.com/${REPO}/releases/download/${tag}/wolfictl_${suffix}_${version}_${suffix}")
done

write_sources "${version}" "${pairs[@]}" >sources.json

echo "Updated sources.json to wolfictl ${version}." >&2
