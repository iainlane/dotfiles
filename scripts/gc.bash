#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils nh
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Garbage collect old generations while retaining the current direnv roots.
#
# Usage: gc <days>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

days="${1}"

ensure_repo_root

nh clean all --keep-since "${days}d" --keep-one

log_note "shells started from older Home Manager generations can keep in-memory hooks to GC'd store paths"
echo "     Re-open existing terminals or run 'exec zsh -l' after cleanup if prompt hooks start failing"
