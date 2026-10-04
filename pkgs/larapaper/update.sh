# shellcheck shell=bash

set -euo pipefail

if (($# > 1)) || [[ "${1:-}" != "" && "${1:-}" != "--force" ]]; then
	echo 'Usage: update-larapaper [--force]' >&2
	exit 1
fi

root="$(git rev-parse --show-toplevel)"
current="$(nix eval --json "${root}#packages.aarch64-linux.larapaper" --apply 'p: { inherit (p) version; inherit (p.src) rev; hash = p.src.outputHash; }')"
tag="$(gh api repos/usetrmnl/larapaper/releases/latest --jq .tag_name)"

if [[ ! "${tag}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Unexpected LaraPaper release tag: ${tag}" >&2
	exit 1
fi

version="${tag#v}"
if [[ "${version}" == "$(jq -r .version <<<"${current}")" && "${1:-}" != "--force" ]]; then
	echo "LaraPaper is already on ${version}." >&2
	exit 0
fi

revision="$(gh api "repos/usetrmnl/larapaper/commits/${tag}" --jq .sha)"
if [[ ! "${revision}" =~ ^[0-9a-f]{40}$ ]]; then
	echo "Unexpected LaraPaper release revision: ${revision}" >&2
	exit 1
fi

prefetched="$(nix flake prefetch --json "github:usetrmnl/larapaper/${revision}")"
hash="$(jq -er .hash <<<"${prefetched}")"
backup="$(mktemp)"
cp package.nix "${backup}"

cleanup() {
	status="$?"
	if ((status != 0)); then
		cp "${backup}" "${root}/pkgs/larapaper/package.nix"
	fi
	rm -f "${backup}"
}
trap cleanup EXIT

python3 - "${current}" "${version}" "${revision}" "${hash}" <<'PY'
import json
import sys
from pathlib import Path

current = json.loads(sys.argv[1])
version, revision, source_hash = sys.argv[2:]
package = Path('package.nix')
text = package.read_text()
for key, value in [('version', version), ('rev', revision), ('hash', source_hash)]:
    before = f'{key} = "{current[key]}";'
    after = f'{key} = "{value}";'
    if text.count(before) != 1:
        raise SystemExit(f'Expected one LaraPaper {key} declaration.')
    text = text.replace(before, after)
package.write_text(text)
PY

cd "${root}"
# applyPatches exposes the original hash, but a source prefetch hashes the
# patched tree. Prefetch the release above and leave source hashing disabled.
nix-update --flake --system aarch64-linux --version=skip --no-src \
	--subpackage frontend --override-filename pkgs/larapaper/package.nix larapaper

echo "Updated LaraPaper to ${version}." >&2
