#!/usr/bin/env nix
#! nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#nix --command bash
# shellcheck shell=bash

# Update chainctl to the latest version.
# Downloads the latest binary to discover the version, then uses
# nix-prefetch-url to compute hashes for all platforms.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BASE_URL="https://dl.enforce.dev/chainctl"

# chainctl_suffix for each Nix system.
declare -A PLATFORMS=(
	[x86_64-linux]=linux_x86_64
	[aarch64-linux]=linux_arm64
	[x86_64-darwin]=darwin_x86_64
	[aarch64-darwin]=darwin_arm64
)

# Discover the latest version.
echo "Fetching latest version..." >&2
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "${BASE_URL}/latest/chainctl_linux_x86_64" -o "$tmp"
chmod +x "$tmp"
version="$("$tmp" version 2>&1 | grep -oP 'GitVersion:\s*\K\S+')"
echo "Latest version: ${version}" >&2

# Build the sources.json by prefetching each platform.
sources='{"version":"'"${version}"'","platforms":{}}'

for system in "${!PLATFORMS[@]}"; do
	suffix="${PLATFORMS[$system]}"
	url="${BASE_URL}/${version}/chainctl_${suffix}"
	echo "Prefetching ${suffix}..." >&2
	hex="$(nix-prefetch-url --type sha256 "$url" 2>/dev/null)"
	sri="$(nix hash convert --hash-algo sha256 --to sri "$hex")"
	sources="$(echo "$sources" | jq \
		--arg sys "$system" \
		--arg url "$url" \
		--arg hash "$sri" \
		'.platforms[$sys] = {url: $url, hash: $hash}')"
done

echo "$sources" | jq --sort-keys . >sources.json

echo "Updated sources.json to chainctl ${version}." >&2
