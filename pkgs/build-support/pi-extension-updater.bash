# shellcheck shell=bash

# Usage: pi-extension-updater.bash CONFIG [--force | --refresh | --pin COMMIT]
#
# Bump a Pi extension: rewrite `source.json` with the new version and source
# hash, and regenerate the build's lockfile under `npm-deps/`. Run from the
# package's directory. CONFIG is the JSON file that `mkPiExtensionUpdater`
# writes.
#
# The registry decides which version to move to, because Pi's own installer
# would resolve the same version. With `gitHub`, the source is that version's
# release tag. An unchanged GitHub source uses its committed lock. npm resolves
# patched sources, pinned commits and registry tarballs.
#
# `--pin COMMIT` replaces the release with an upstream commit from the
# repository that npm records for the package. Updates keep the pin until npm
# reports a release built from a commit (`gitHead`) that contains the pinned
# commit, and then return to that release.

set -euo pipefail

config="$1"
shift

setting() {
	jq -r "$1" "${config}"
}

# shellcheck disable=SC1090
source "$(setting .prefetch)"

npmName="$(setting .npmName)"
pname="$(setting .pname)"
tagPrefix="$(setting .tagPrefix)"
gitHubOwner="$(setting '.gitHub.owner // empty')"
gitHubRepo="$(setting '.gitHub.repo // empty')"

tmpdir="$(mktemp -d)"
sourceDir="${tmpdir}/source"
mkdir "${sourceDir}"

# Keep the temporary files beside their destinations so the renames stay
# atomic.
staged="$(mktemp source.json.XXXXXX)"
stagedLock="$(mktemp npm-deps/package-lock.json.XXXXXX)"
metadataStages=()
metadataDestinations=()
trap 'rm -rf "${tmpdir}" "${staged}" "${stagedLock}" "${metadataStages[@]}"' EXIT

# Leave the caller's npm cache alone; this run only reads metadata.
export npm_config_cache="${tmpdir}/npm-cache"

# Print the GitHub owner, repository and package directory that npm records
# for the latest release. The directory is empty when the package is the
# repository root.
npm_repository() {
	local repository url directory path

	repository="$(npm view "${npmName}" repository --json)"
	url="$(jq -r 'if type == "string" then . else .url end' <<<"${repository}")"
	directory="$(jq -r 'if type == "object" then .directory // "" else "" end' <<<"${repository}")"

	url="${url#git+}"
	url="${url%.git}"

	case "${url}" in
	https://github.com/*/*) ;;
	*)
		echo "npm records ${npmName}'s repository as ${url}, which is not a GitHub URL." >&2
		return 1
		;;
	esac

	path="${url#https://github.com/}"
	printf '%s %s %s\n' "${path%%/*}" "${path#*/}" "${directory}"
}

# Download a commit's GitHub archive to `tarball`, move `directory` (the whole
# repository when empty) to the source directory, and set `hash` to the value
# that `fetchFromGitHub` records for it with `rootDir`.
fetch_commit() {
	local owner="$1" repo="$2" directory="$3" rev="$4"
	local archive="${tmpdir}/archive"

	tarball="${tmpdir}/${pname}.tar.gz"
	download "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz" "${tarball}"

	mkdir "${archive}"
	tar -xzf "${tarball}" -C "${archive}" --strip-components=1

	rm -rf "${sourceDir}"
	mv "${archive}${directory:+/${directory}}" "${sourceDir}"

	hash="$(nix hash path "${sourceDir}")"
	commitSource=true
	metadataPrefix="${directory:+${directory}/}"
}

# Return 0 when `commit` is an ancestor of `release`, 1 when it is not, and 2
# when the check fails. The fetch omits trees, so it downloads commit history
# only.
release_contains_commit() {
	local owner="$1" repo="$2" commit="$3" release="$4"
	local repository="${tmpdir}/history" status=0

	git init --quiet --bare "${repository}" || return 2
	git -C "${repository}" fetch --quiet --filter=tree:0 \
		"https://github.com/${owner}/${repo}.git" "${commit}" "${release}" || return 2

	git -C "${repository}" merge-base --is-ancestor "${commit}" "${release}" || status=$?

	case "${status}" in
	0 | 1)
		return "${status}"
		;;
	*)
		return 2
		;;
	esac
}

pin_commit() {
	local rev="$1" repository owner repo directory

	if [[ ! "${rev}" =~ ^[0-9a-f]{40}$ ]]; then
		echo 'Pass the full commit hash to --pin.' >&2
		exit 1
	fi

	repository="$(npm_repository)"
	read -r owner repo directory <<<"${repository}"

	fetch_commit "${owner}" "${repo}" "${directory}" "${rev}"
	version="$(jq -r .version "${sourceDir}/package.json")"

	jq --sort-keys \
		--arg owner "${owner}" \
		--arg repo "${repo}" \
		--arg directory "${directory}" \
		--arg rev "${rev}" \
		--arg hash "${hash}" \
		--arg version "${version}" \
		'.pin = {owner: $owner, repo: $repo, rev: $rev, hash: $hash, version: $version}
			+ (if $directory == "" then {} else {directory: $directory} end)' \
		source.json >"${staged}"

	echo "Pinning ${pname} to ${rev} (${version})" >&2
}

refresh_pin() {
	fetch_commit \
		"$(jq -r .pin.owner source.json)" \
		"$(jq -r .pin.repo source.json)" \
		"$(jq -r '.pin.directory // ""' source.json)" \
		"${pinnedRev}"

	if [[ "$(jq -r .pin.hash source.json)" != "${hash}" ]]; then
		echo 'The pinned source hash changed; refusing to repin during refresh.' >&2
		exit 1
	fi

	version="$(jq -r .pin.version source.json)"
	cp source.json "${staged}"
}

# Exit when the release in `version` does not contain the pinned commit.
keep_unreleased_pin() {
	local gitHead status=0

	gitHead="$(npm view "${npmName}@${version}" gitHead)"
	if [[ -z "${gitHead}" ]]; then
		echo "Keeping ${pname} pinned to ${pinnedRev}: npm does not record the commit of release ${version}." >&2
		exit 0
	fi

	release_contains_commit \
		"$(jq -r .pin.owner source.json)" \
		"$(jq -r .pin.repo source.json)" \
		"${pinnedRev}" \
		"${gitHead}" || status=$?

	case "${status}" in
	0)
		echo "Release ${version} contains the pinned commit ${pinnedRev}; returning ${pname} to releases" >&2
		;;
	1)
		echo "Keeping ${pname} pinned to ${pinnedRev}: release ${version} does not contain it." >&2
		exit 0
		;;
	*)
		echo "Could not check whether release ${version} contains ${pinnedRev}." >&2
		exit 1
		;;
	esac
}

fetch_release_tag() {
	local tag="${tagPrefix}${version}" url

	if [[ "${mode}" == refresh ]]; then
		tag="$(jq -r --arg prefix "${tagPrefix}" '.rev // .tag // ($prefix + .version)' source.json)"
	fi
	url="https://github.com/${gitHubOwner}/${gitHubRepo}/archive/${tag}.tar.gz"

	# `fetchFromGitHub` records the hash of the unpacked tree, so `--unpack`
	# produces the matching value. `nix-prefetch-url` prints base32, and
	# `nix hash convert` turns it into the SRI form.
	hash="$(nix hash convert --hash-algo sha256 --to sri \
		"$(nix-prefetch-url --unpack --type sha256 "${url}")")"

	tarball="${tmpdir}/${pname}.tar.gz"
	download "${url}" "${tarball}"

	tar -xzf "${tarball}" -C "${sourceDir}" --strip-components=1

	jq -n --sort-keys \
		--arg version "${version}" \
		--arg tag "${tag}" \
		--arg hash "${hash}" \
		'{version: $version, tag: $tag, hash: $hash}' >"${staged}"
}

fetch_registry_tarball() {
	tarball="${tmpdir}/${pname}.tgz"
	download "https://registry.npmjs.org/${npmName}/-/${pname}-${version}.tgz" "${tarball}"

	tar -xzf "${tarball}" -C "${sourceDir}" --strip-components=1

	# A failing `hash_file` inside the `jq` arguments would not change `jq`'s
	# exit status, so `source.json` would be written with an empty
	# `tarballHash`. Assign the hash first so errexit stops the script.
	hash="$(hash_file "${tarball}")"

	jq -n --sort-keys \
		--arg version "${version}" \
		--arg hash "${hash}" \
		'{version: $version, tarballHash: $hash}' >"${staged}"
}

update_release() {
	local force=false

	if [[ "${mode}" == force ]]; then
		force=true
	fi

	if [[ "${mode}" == refresh ]]; then
		version="${current}"
	else
		version="$(npm view "${npmName}" version)"
	fi

	if [[ -n "${pinnedRev}" ]]; then
		keep_unreleased_pin
		force=true
	fi

	# Some changes need the lockfile rebuilt without a version bump: moving a
	# package to a GitHub source, or editing `npmDependencies`. `--force` asks
	# for that.
	if [[ "${version}" == "${current}" ]]; then
		if ! ${force} && [[ "${mode}" != refresh ]]; then
			echo "${pname} is already on the latest version (${version}); pass --force to resolve it again" >&2
			exit 0
		fi

		echo "Resolving ${pname} ${version} again" >&2
	else
		echo "Bumping ${pname}: ${current} -> ${version}" >&2
	fi

	if [[ -n "${gitHubOwner}" ]]; then
		fetch_release_tag
	else
		fetch_registry_tarball
	fi

	if [[ "${mode}" == refresh ]]; then
		if [[ "$(jq -r '.hash // .tarballHash' source.json)" != "${hash}" ]]; then
			echo 'The pinned source hash changed; refusing to repin during refresh.' >&2
			exit 1
		fi

		cp source.json "${staged}"
	fi
}

usage() {
	echo "Usage: update-${pname} [--force | --refresh | --pin <commit>]" >&2
	exit 1
}

mode=release
case "$#:${1:-}" in
0:) ;;
1:--force | 1:--refresh)
	mode="${1#--}"
	;;
2:--pin)
	mode=pin
	;;
*)
	usage
	;;
esac

current="$(jq -r .version source.json)"
pinnedRev="$(jq -r '.pin.rev // empty' source.json)"
commitSource=false
metadataPrefix=""

if [[ "${mode}" == pin ]]; then
	pin_commit "$2"
elif [[ -n "${pinnedRev}" && "${mode}" == refresh ]]; then
	refresh_pin
else
	update_release
fi

while IFS= read -r sourcePatch; do
	(cd "${sourceDir}" && patch --batch --forward -p1 --input "${sourcePatch}") >&2
done < <(setting '.patches[]')

if [[ "$(setting '.npmDependencies | length')" != 0 ]]; then
	jq --argjson deps "$(jq -c .npmDependencies "${config}")" \
		--from-file "$(setting .promoteDependencies)" \
		"${sourceDir}/package.json" >"${sourceDir}/package.json.new"
	mv "${sourceDir}/package.json.new" "${sourceDir}/package.json"
fi

if ${commitSource} || [[ -z "${gitHubOwner}" || "$(setting '(.patches | length) + (.npmDependencies | length)')" != 0 ]]; then
	(cd "${sourceDir}" && npm install --package-lock-only --ignore-scripts) >&2
fi
lockfile="${sourceDir}/package-lock.json"

jq --exit-status --arg version "${version}" --arg name "${npmName}" '
	.packages[""].version == $version
	and .packages[""].name == $name
	and (.lockfileVersion == 2 or .lockfileVersion == 3)
' "${lockfile}" >/dev/null

# The build uses the lockfile's root record as its manifest, but npm leaves the
# manifest's `overrides` out of the lockfile. Without them, the build's npm
# finds the overridden edges invalid and tries to fetch the versions that the
# overrides replaced.
if jq --exit-status 'has("overrides")' "${sourceDir}/package.json" >/dev/null; then
	jq --slurpfile manifest "${sourceDir}/package.json" \
		'.packages[""].overrides = $manifest[0].overrides' \
		"${lockfile}" >"${tmpdir}/package-lock.json"
	lockfile="${tmpdir}/package-lock.json"
fi

verify="${tmpdir}/verify"
mkdir "${verify}"
cp "${lockfile}" "${verify}/package-lock.json"
jq '.packages[""]' "${lockfile}" >"${verify}/package.json"
(cd "${verify}" && npm ls --all --package-lock-only >/dev/null)

while IFS=$'\t' read -r destination sourcePath; do
	stagedFile="$(mktemp "${destination}.XXXXXX")"
	metadataStages+=("${stagedFile}")
	metadataDestinations+=("${destination}")

	tar -xOzf "${tarball}" --wildcards "*/${metadataPrefix}${sourcePath}" >"${stagedFile}"
	jq --exit-status 'type == "object"' "${stagedFile}" >/dev/null
done < <(setting '.metadataFiles | to_entries[] | "\(.key)\t\(.value)"')

cp "${lockfile}" "${stagedLock}"
mv "${stagedLock}" npm-deps/package-lock.json
mv "${staged}" source.json
for index in "${!metadataDestinations[@]}"; do
	mv "${metadataStages[${index}]}" "${metadataDestinations[${index}]}"
done

echo "Updated ${pname} to ${version}." >&2
