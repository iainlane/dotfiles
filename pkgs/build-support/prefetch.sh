# shellcheck shell=bash
# Shared helpers for the prebuilt-binary update scripts. Sourced, not executed.
#
# chainctl and wolfictl both pin one upstream binary per platform: discover a
# version, then download and hash each platform's binary. Version discovery and
# the URL layout differ between them, but the download, hashing and
# sources.json assembly are identical and live here.

# Download a URL to a path, showing wget's progress bar (size, rate, ETA).
download() {
	local url="$1" out="$2"

	wget --show-progress -qO "$out" "$url"
}

# Print the SRI hash of a file, in the form fetchurl expects.
hash_file() {
	local path="$1"

	nix hash file --sri --type sha256 "$path"
}

# Assemble sources.json from a version and a list of `system=url` pairs,
# downloading and hashing each platform's binary.
#
#   write_sources "$version" "x86_64-linux=https://..." "aarch64-linux=https://..."
write_sources() {
	local version="$1"
	shift

	local tmpdir
	tmpdir="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf '${tmpdir}'" RETURN

	local sources
	sources="$(jq -n --arg version "${version}" '{version: $version, platforms: {}}')"

	local pair system url hash
	for pair in "$@"; do
		system="${pair%%=*}"
		url="${pair#*=}"

		echo "Downloading ${system}..." >&2
		download "${url}" "${tmpdir}/${system}"
		hash="$(hash_file "${tmpdir}/${system}")"

		sources="$(echo "${sources}" | jq \
			--arg sys "${system}" \
			--arg url "${url}" \
			--arg hash "${hash}" \
			'.platforms[$sys] = {url: $url, hash: $hash}')"
	done

	echo "${sources}" | jq --sort-keys .
}
