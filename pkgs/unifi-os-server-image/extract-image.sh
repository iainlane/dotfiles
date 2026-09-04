# shellcheck shell=bash
# Extract the embedded OCI image archive and its tag from a UniFi OS Server
# installer. Run both at build time (image.nix) and by update.sh, so the
# binwalk and tar logic lives in one place.
#
# Usage: extract-image.sh <installer> <output-dir>
# Writes <output-dir>/image.tar and <output-dir>/image-tag.

set -euo pipefail

installer="$1"
outdir="$2"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

binwalk --extract --directory "${workdir}/extract" "${installer}" >/dev/null

image_tar="$(find "${workdir}/extract" -type f -name image.tar | head -n1)"

if [[ -z "${image_tar}" ]]; then
	echo "Could not find embedded image.tar in UniFi installer." >&2
	exit 1
fi

image_tag="$(tar -xOf "${image_tar}" manifest.json | jq -r '.[0].RepoTags[0] // empty')"

if [[ -z "${image_tag}" ]]; then
	echo "Could not determine embedded image tag from image.tar." >&2
	exit 1
fi

mkdir -p "${outdir}"
cp "${image_tar}" "${outdir}/image.tar"
printf '%s\n' "${image_tag}" >"${outdir}/image-tag"
