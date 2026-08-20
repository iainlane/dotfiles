#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Pre-build the configured development shells and refresh their direnv caches.
#
# Usage: build-direnvs

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

ensure_repo_root

hostname="$(hostname -s)"
if ! direnv_bin="$(command -v direnv)"; then
	die "direnv is not available"
fi

project_dirs="$(
	nix eval --raw --apply '
    config:
      builtins.concatStringsSep "\n" (
        map
          (path:
            if builtins.substring 0 1 path == "/"
            then path
            else config.home.homeDirectory + "/" + path)
          (builtins.attrNames config.programs.projectDirectories.directories)
      )
  ' ".#homeConfigurations.\"${USER}@${hostname}\".config"
)"

nix build .#direnv-shells --profile "${XDG_STATE_HOME:-${HOME}/.local/state}/nix/profiles/direnv-shells"

while IFS= read -r project_dir; do
	[[ -n "${project_dir}" ]] || continue
	[[ -f "${project_dir}/.envrc" ]] || continue

	if ! "${direnv_bin}" exec "${project_dir}" true >/dev/null; then
		log_warn "failed to refresh direnv cache for ${project_dir}"
	fi
done <<<"${project_dirs}"
