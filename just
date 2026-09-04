#!/usr/bin/env bash

# Run `just` via Nix so it doesn't have to be installed.
# `nh` comes from this flake's unstable package set.

set -euo pipefail

ulimit -n 4096

cd "$(dirname "$0")"

exec nix shell \
  nixpkgs#age \
  nixpkgs#coreutils \
  nixpkgs#gh \
  nixpkgs#just \
  nixpkgs#mkpasswd \
  nixpkgs#nvd \
  nixpkgs#openssl \
  nixpkgs#sops \
  nixpkgs#ssh-to-age \
  nixpkgs#yq-go \
  .#nh \
  --command just "$@"
