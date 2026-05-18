#!/usr/bin/env nix
#! nix shell nixpkgs#bash nixpkgs#binwalk nixpkgs#curl nixpkgs#jq nixpkgs#openssl nixpkgs#unzip --command bash
# shellcheck shell=bash

# Update UniFi OS Server to the latest Linux release published by Ubiquiti.
# Fetches the official downloads API, selects the latest Linux arm64/x64
# installers, extracts the embedded OCI tag, computes SRI hashes, and rewrites
# sources.json.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

API_URL="https://download.svc.ui.com/v1/software-downloads"

payload="$(curl -fsSL "${API_URL}")"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

version="$(
	printf '%s' "${payload}" | jq -r '
		[
			.downloads[]
			| select(.name | test("^UniFi OS Server [0-9.]+ for Linux \\((x64|arm64)\\)$"))
		]
		| sort_by(.version | split(".") | map(tonumber))
		| last
		| .version
	'
)"

if [[ -z "${version}" || "${version}" == "null" ]]; then
	echo "Could not determine latest UniFi OS Server Linux release." >&2
	exit 1
fi

echo "Latest version: ${version}" >&2

x64_url="$(
	printf '%s' "${payload}" | jq -r --arg version "${version}" '
		.downloads[]
		| select(.version == $version and .name == ("UniFi OS Server " + $version + " for Linux (x64)"))
		| .file_url
	'
)"

arm64_url="$(
	printf '%s' "${payload}" | jq -r --arg version "${version}" '
		.downloads[]
		| select(.version == $version and .name == ("UniFi OS Server " + $version + " for Linux (arm64)"))
		| .file_url
	'
)"

if [[ -z "${x64_url}" || "${x64_url}" == "null" || -z "${arm64_url}" || "${arm64_url}" == "null" ]]; then
	echo "Could not find Linux x64 and arm64 installers for UniFi OS Server ${version}." >&2
	exit 1
fi

prefetch_sri() {
	local path="${1}"
	local base64_hash

	base64_hash="$(openssl dgst -sha256 -binary "${path}" | openssl base64 -A)"
	printf 'sha256-%s\n' "${base64_hash}"
}

echo "Downloading Linux arm64 installer..." >&2
arm64_installer="${tmpdir}/unifi-os-server-arm64.bin"
curl -fsSL "${arm64_url}" -o "${arm64_installer}"

echo "Downloading Linux x64 installer..." >&2
x64_installer="${tmpdir}/unifi-os-server-x64.bin"
curl -fsSL "${x64_url}" -o "${x64_installer}"

echo "Extracting embedded image tag..." >&2
binwalk --extract --directory "${tmpdir}/extract" "${arm64_installer}" >/dev/null
image_tar="$(find "${tmpdir}/extract" -type f -name image.tar | head -n1)"

if [[ -z "${image_tar}" ]]; then
	echo "Could not find embedded image.tar in UniFi installer." >&2
	exit 1
fi

image_tag="$(tar -xOf "${image_tar}" manifest.json | jq -r '.[0].RepoTags[0] // empty')"

if [[ -z "${image_tag}" ]]; then
	echo "Could not determine embedded image tag from image.tar." >&2
	exit 1
fi

echo "Prefetching Linux x64..." >&2
x64_hash="$(prefetch_sri "${x64_installer}")"

echo "Prefetching Linux arm64..." >&2
arm64_hash="$(prefetch_sri "${arm64_installer}")"

jq -n \
	--arg image_tag "${image_tag}" \
	--arg version "${version}" \
	--arg x64_url "${x64_url}" \
	--arg x64_hash "${x64_hash}" \
	--arg arm64_url "${arm64_url}" \
	--arg arm64_hash "${arm64_hash}" \
	'{
		imageTag: $image_tag,
		version: $version,
		platforms: {
			"aarch64-linux": {
				url: $arm64_url,
				hash: $arm64_hash
			},
			"x86_64-linux": {
				url: $x64_url,
				hash: $x64_hash
			}
		}
	}' >sources.json

echo "Updated sources.json to UniFi OS Server ${version}." >&2
