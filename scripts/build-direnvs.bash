#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Pre-build the development shells this host's project directories load, and
# refresh their direnv caches.
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

# One line per project directory: its absolute path, a tab, and the flake
# attribute of the shell its `.envrc` loads. `attrSegments` is what
# lib/project-directories writes into that `.envrc`, and the flat devShell for
# the same segments is what `nix build` can take on the command line.
project_shells="$(
	nix eval --raw --apply '
    homeConfiguration: let
      inherit (homeConfiguration) config pkgs;

      # A host without any project shells never has the option declared.
      directories = config.programs.projectDirectories.directories or {};

      absolutePath = path:
        if builtins.substring 0 1 path == "/"
        then path
        else config.home.homeDirectory + "/" + path;

      line = path: directory:
        absolutePath path
        + "\t.#devShells."
        + pkgs.stdenv.hostPlatform.system
        + ".direnvs-"
        + builtins.concatStringsSep "-" directory.attrSegments;
    in
      builtins.concatStringsSep "\n" (
        builtins.attrValues (builtins.mapAttrs line directories)
      )
  ' ".#homeConfigurations.\"${USER}@${hostname}\""
)"

project_dirs=()
shell_attrs=()

while IFS=$'\t' read -r project_dir shell_attr; do
	[[ -n "${project_dir}" ]] || continue

	project_dirs+=("${project_dir}")
	shell_attrs+=("${shell_attr}")
done <<<"${project_shells}"

# Each symlink is an indirect garbage-collector root, so the shells survive a
# `nix-collect-garbage` until this script runs again. `nix build` uses
# `--out-link` as the base name and numbers the additional output links, so the
# directory is emptied first and the links are numbered from scratch.
gcroots="${XDG_STATE_HOME:-${HOME}/.local/state}/nix/direnv-shells"
rm -rf "${gcroots}"

if [[ ${#shell_attrs[@]} -gt 0 ]]; then
	mkdir -p "${gcroots}"
	nix build "${shell_attrs[@]}" --out-link "${gcroots}/shell"
fi

for project_dir in ${project_dirs[@]+"${project_dirs[@]}"}; do
	[[ -f "${project_dir}/.envrc" ]] || continue

	if ! "${direnv_bin}" exec "${project_dir}" true >/dev/null; then
		log_warn "failed to refresh direnv cache for ${project_dir}"
	fi
done
