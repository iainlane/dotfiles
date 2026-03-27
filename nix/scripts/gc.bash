#!/usr/bin/env bash

# Garbage collect old generations, rebuild cached direnv shells, and refresh
# project direnv caches.
#
# Usage: gc <days> <xdg_state_home>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

days="${1}"
xdg_state_home="${2}"

ensure_repo_root

hostname="$(hostname -s)"
direnv_bin="/etc/profiles/per-user/${USER}/bin/direnv"
if [[ ! -x "${direnv_bin}" ]]; then
	direnv_bin="$(command -v direnv || true)"
fi
if [[ -z "${direnv_bin}" ]]; then
	die "direnv is not available"
fi

# Different hosts expose projectDirectories through different top-level configs.
project_dirs="$(
	nix eval --raw --apply 'dirs: builtins.concatStringsSep "\n" (builtins.attrNames dirs)' ".#homeConfigurations.\"${USER}@${hostname}\".config.programs.projectDirectories.directories" 2>/dev/null ||
		nix eval --raw --apply 'dirs: builtins.concatStringsSep "\n" (builtins.attrNames dirs)' ".#darwinConfigurations.${hostname}.config.home-manager.users.${USER}.programs.projectDirectories.directories" 2>/dev/null ||
		nix eval --raw --apply 'dirs: builtins.concatStringsSep "\n" (builtins.attrNames dirs)' ".#nixosConfigurations.${hostname}.config.home-manager.users.${USER}.programs.projectDirectories.directories" 2>/dev/null ||
		true
)"

nh clean all --keep-since "${days}d"
nix build .#direnv-shells --profile "${xdg_state_home}/nix/profiles/direnv-shells"

while IFS= read -r dir_path; do
	[[ -n "${dir_path}" ]] || continue

	# projectDirectories can be configured as absolute paths or paths under $HOME.
	if [[ "${dir_path}" = /* ]]; then
		project_dir="${dir_path}"
	else
		project_dir="${HOME}/${dir_path}"
	fi

	[[ -f "${project_dir}/.envrc" ]] || continue

	rm -rf "${project_dir}/.direnv"

	if ! "${direnv_bin}" exec "${project_dir}" true >/dev/null; then
		log_warn "failed to refresh direnv cache for ${project_dir}"
	fi
done <<<"${project_dirs}"

log_note "shells started from older Home Manager generations can keep in-memory hooks to GC'd store paths"
echo "     Re-open existing terminals or run 'exec zsh -l' after cleanup if prompt hooks start failing"
