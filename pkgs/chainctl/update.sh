#!/usr/bin/env nix
#! nix shell nixpkgs#bash nixpkgs#gnugrep nixpkgs#jq nixpkgs#nix nixpkgs#wget --command bash
# shellcheck shell=bash

# Update chainctl to the latest version.
# The vendor exposes no version metadata, so we download the latest binary and
# ask it, then download and hash the binary for every platform.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck source-path=SCRIPTDIR source=../_lib/prefetch.sh
source ../_lib/prefetch.sh

BASE_URL="https://dl.enforce.dev/chainctl"

# chainctl suffix for each Nix system.
declare -A PLATFORMS=(
	["x86_64-linux"]=linux_x86_64
	["aarch64-linux"]=linux_arm64
	["x86_64-darwin"]=darwin_x86_64
	["aarch64-darwin"]=darwin_arm64
)

# Discover the latest version by running the binary.
echo "Discovering latest version..." >&2
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
download "${BASE_URL}/latest/chainctl_linux_x86_64" "${tmp}"
chmod +x "${tmp}"
version="$("${tmp}" version 2>&1 | grep -oP 'GitVersion:\s*\K\S+')"
echo "Latest version: ${version}" >&2

pairs=()
for system in "${!PLATFORMS[@]}"; do
	pairs+=("${system}=${BASE_URL}/${version}/chainctl_${PLATFORMS[${system}]}")
done

write_sources "${version}" "${pairs[@]}" >sources.json

echo "Updated sources.json to chainctl ${version}." >&2
