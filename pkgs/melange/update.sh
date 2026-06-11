#!/usr/bin/env nix
#! nix shell nixpkgs#bash nixpkgs#nix-update --command bash
# shellcheck shell=bash

# Update melange to the latest version.
# Uses nix-update to bump version, source hash, and vendor hash in package.nix.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

nix-update \
	--flake \
	--override-filename pkgs/melange/package.nix \
	--use-github-releases \
	melange
