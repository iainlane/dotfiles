#!/usr/bin/env nix
#! nix shell nixpkgs#bash nixpkgs#nix-update --command bash
# shellcheck shell=bash

# Update melange to the latest version.
# Uses nix-update to bump version, source hash, and vendor hash in package.nix.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

nixpkgs_path="$(nix eval --raw nixpkgs#path)"

nix-update \
	-f "$nixpkgs_path" \
	--override-filename package.nix \
	--use-github-releases \
	melange
