#!/usr/bin/env bash

# Build a host-specific NixOS ISO by composing remote-built contents into a
# local image.
#
# Usage: build-iso <host>

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

host="${1}"

ensure_repo_root

build_system="$(nix eval --impure --expr 'builtins.currentSystem' --raw)"
host_system="$(nix eval ".#nixosConfigurations.${host}.config.nixpkgs.system" --raw)"
remote_store="ssh-ng://nixbuild-store"
contents_drv=".#packages.${host_system}.${host}-iso-contents"

log_step "Building ISO contents for ${host} (${host_system}) via ${remote_store}"
build_json="$(nix build --eval-store auto --store "${remote_store}" --json --no-link "${contents_drv}")"
out_path="$(printf '%s' "${build_json}" | nix run nixpkgs#jq -- -r '.[0].outputs.out')"

log_step "Copying ISO contents to the local store"
nix copy --from "${remote_store}?trusted=1" "${out_path}"

log_step "Assembling ISO locally on ${build_system}"
nix build ".#packages.${build_system}.${host}-iso" --out-link "${host}-iso"

# Without nullglob, a non-matching glob would be passed through literally.
shopt -s nullglob
isos=("${host}-iso"/iso/*.iso)
shopt -u nullglob

if [[ ${#isos[@]} -eq 0 ]]; then
	die "no ISO was produced for ${host}"
fi

log_step "ISO built: ${isos[0]}"
echo "    Write to USB with: dd if=${isos[0]} of=/dev/sdX bs=4M status=progress oflag=sync"
