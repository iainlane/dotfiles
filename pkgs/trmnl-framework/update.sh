# shellcheck shell=bash

set -euo pipefail

if (($# > 1)) || [[ "${1:-}" != "" && "${1:-}" != "--force" ]]; then
	echo 'Usage: update-trmnl-framework [--force]' >&2
	exit 1
fi

tag="$(gh api repos/usetrmnl/trmnl-framework/releases/latest --jq .tag_name)"
if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Unexpected framework release tag: ${tag}" >&2
	exit 1
fi

version="${tag#v}"
current="$(jq -r .version source.json)"
if [[ "${version}" == "${current}" && "${1:-}" != "--force" ]]; then
	echo "TRMNL framework is already on ${version}." >&2
	exit 0
fi

prefetched="$(nix flake prefetch --json "github:usetrmnl/trmnl-framework/${tag}")"
hash="$(jq -er .hash <<<"${prefetched}")"
staged="$(mktemp source.json.XXXXXX)"
trap 'rm -f "${staged}"' EXIT

jq --arg version "${version}" --arg hash "${hash}" '
  if .version != $version then
    .legacy += [{version: .version, hash: .hash}]
    | .legacy |= unique_by(.version)
  else . end
  | .version = $version
  | .hash = $hash
' source.json >"${staged}"
mv "${staged}" source.json

echo "Updated TRMNL framework to ${version}." >&2
