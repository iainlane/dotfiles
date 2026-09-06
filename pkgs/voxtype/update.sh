# shellcheck shell=bash

# Move voxtype to the head of the fork branch this flake pins, and refresh the
# committed `Cargo.lock` from the same revision, so the source and the
# dependency pins stay consistent.
#
# nix-update cannot do this: the branch has no tags, and the revision lives in
# `source.json` instead of an argument of the `fetchFromGitHub` call.

OWNER="iainlane"
REPO="voxtype"
BRANCH="dotfiles"

echo "Discovering latest version..." >&2
revision="$(gh api "repos/${OWNER}/${REPO}/commits/${BRANCH}" --jq .sha)"
current="$(jq -r .revision source.json)"

if [[ "${revision}" == "${current}" ]]; then
	echo "voxtype is already on ${OWNER}/${REPO}@${BRANCH} (${revision})." >&2
	exit 0
fi

echo "Bumping voxtype: ${current} -> ${revision}" >&2

# `nix flake prefetch` on a `github:` reference returns the unpacked tree's NAR
# hash and its store path. `fetchFromGitHub` wants that hash, and `Cargo.lock`
# is copied from that tree.
prefetched="$(nix flake prefetch --json "github:${OWNER}/${REPO}/${revision}")"
hash="$(jq -r .hash <<<"${prefetched}")"
tree="$(jq -r .storePath <<<"${prefetched}")"

version="$(
	nix eval --raw --impure --expr \
		"(builtins.fromTOML (builtins.readFile ${tree}/Cargo.toml)).package.version"
)"

install -m 644 "${tree}/Cargo.lock" Cargo.lock

# Write the new pin to a temporary file beside `source.json`, so a failure
# leaves the old pin in place and the final rename stays atomic.
staged="$(mktemp source.json.XXXXXX)"
trap 'rm -f "${staged}"' EXIT

jq -n --sort-keys \
	--arg hash "${hash}" \
	--arg revision "${revision}" \
	--arg version "${version}" \
	'{hash: $hash, revision: $revision, version: $version}' >"${staged}"
mv "${staged}" source.json

echo "Updated voxtype to ${version} (${revision})." >&2
