#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Refresh this host's project directory caches after its shells have been built
# through Home Manager. --after-switch also retires the old separate roots.
#
# Usage: refresh-direnvs [--after-switch]

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

ensure_repo_root

after_switch=false
if [[ $# -gt 0 ]]; then
	[[ $# -eq 1 && "$1" == --after-switch ]] || die "usage: refresh-direnvs [--after-switch]"
	after_switch=true
fi

hostname="$(hostname -s)"
configured_user="$(
	nix eval --option allow-import-from-derivation false --raw .#.username
)" || die "Could not read the configured Home Manager user."
if ! direnv_bin="$(command -v direnv)"; then
	die "direnv is not available"
fi

project_dirs="$(
	nix eval --option allow-import-from-derivation false --raw --apply '
    home: let
      inherit (home) config;
      directories =
        if config.programs.projectDirectories.enable or false
        then config.programs.projectDirectories.directories
        else {};

      absolutePath = path:
        if builtins.substring 0 1 path == "/"
        then path
        else config.home.homeDirectory + "/" + path;
    in
      builtins.concatStringsSep "\n" (map absolutePath (builtins.attrNames directories))
  ' ".#.homeResults.\"${configured_user}@${hostname}\""
)"

failed=0
while IFS= read -r project_dir; do
	[[ -n "${project_dir}" ]] || continue

	if [[ ! -f "${project_dir}/.envrc" ]]; then
		log_warn "missing .envrc for ${project_dir}; switch the home configuration before refreshing"
		failed=1
		continue
	fi

	unset NIX_DIRENV_DID_FALLBACK
	if ! "${direnv_bin}" exec "${project_dir}" "${BASH}" -c "test \"\${NIX_DIRENV_DID_FALLBACK:-0}\" != 1" >/dev/null; then
		log_warn "failed to refresh direnv cache for ${project_dir}"
		failed=1
	fi
done <<<"${project_dirs}"

[[ "${failed}" -eq 0 ]] || exit 1

if "${after_switch}"; then
	rm -rf -- "${XDG_STATE_HOME:-${HOME}/.local/state}/nix/direnv-shells"
fi
