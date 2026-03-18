#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq nix

# Update wolfictl to the latest version.
# Fetches the latest GitHub release, then uses nix-prefetch-url to compute
# hashes for all platform binaries.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

REPO="wolfi-dev/wolfictl"

# Nix system → goreleaser os_arch suffix.
declare -A PLATFORMS=(
  [x86_64-linux]=linux_amd64
  [aarch64-linux]=linux_arm64
  [x86_64-darwin]=darwin_amd64
  [aarch64-darwin]=darwin_arm64
)

# Get the latest version from GitHub.
echo "Fetching latest version..." >&2
tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | jq -r .tag_name)"
version="${tag#v}"
echo "Latest version: ${version}" >&2

# Build sources.json by prefetching each platform binary.
sources='{"version":"'"${version}"'","platforms":{}}'

for system in "${!PLATFORMS[@]}"; do
  suffix="${PLATFORMS[$system]}"
  url="https://github.com/${REPO}/releases/download/${tag}/wolfictl_${suffix}_${version}_${suffix}"
  echo "Prefetching ${suffix}..." >&2
  hex="$(nix-prefetch-url --type sha256 "$url" 2>/dev/null)"
  sri="$(nix hash convert --hash-algo sha256 --to sri "$hex")"
  sources="$(echo "$sources" | jq \
    --arg sys "$system" \
    --arg url "$url" \
    --arg hash "$sri" \
    '.platforms[$sys] = {url: $url, hash: $hash}')"
done

echo "$sources" | jq --sort-keys . > sources.json

echo "Updated sources.json to wolfictl ${version}." >&2
