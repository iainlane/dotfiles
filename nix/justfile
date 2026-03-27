#!/usr/bin/env just --justfile
# Nix dotfiles management commands

set shell := ["bash", "-c", "ulimit -n 4096; set -euo pipefail; eval \"$1\"", "-"]

# GitHub token for private repo access (appended to NIX_CONFIG for all recipes)

gh-token := `gh auth token 2>/dev/null || true`
export GITHUB_TOKEN := gh-token
nix-config-base := env('NIX_CONFIG', '')
nix-config-sep := if nix-config-base != '' { "\n" } else { "" }
export NIX_CONFIG := nix-config-base + nix-config-sep + "access-tokens = github.com=" + gh-token + "\nimpure-env = GITHUB_TOKEN=" + gh-token
xdg_state_home := env('XDG_STATE_HOME', env('HOME') + "/.local/state")

# Secrets repository URL (cloned for key management)

secrets_repo := "git+ssh://git@github.com/iainlane/dotfiles-secrets"

# Platform-specific system rebuild command

system-profile := if os() == "macos" { "/nix/var/nix/profiles/system" } else { "/nix/var/nix/profiles/system" }

# Default recipe: list available commands
default:
    @just --list

# Update flake inputs (all, or specific ones if provided)
update-flake *inputs:
    nix flake update {{ inputs }}

# Rebuild and switch to the new system configuration
[macos]
update-system *args:
    nh darwin switch . {{ args }}

[linux]
update-system *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -f /etc/NIXOS ]]; then
        nh os switch {{ args }} .
    else
        # system-manager (nh doesn't support system-manager yet)
        sudo --preserve-env=NIX_CONFIG /nix/var/nix/profiles/default/bin/nix run .#system-manager -- switch --flake . {{ args }}
    fi

# Rebuild and switch to the new home-manager configuration. Linux only. On mac,

# home-manager is integrated into darwin-rebuild.
[linux]
update-home *args:
    nh home switch . {{ args }}

[linux]
update: update-flake update-system update-home build-direnvs

[macos]
update: update-flake update-system build-direnvs

# Deploy to a remote host via deploy-rs (all profiles by default)
update-host hostname *args:
    nix run .#deploy-rs -- --interactive-sudo true --hostname '{{ hostname }}.home.orangesquash.org.uk' .#{{ hostname }} {{ args }}

# Pre-build all direnv development shells for faster directory changes
build-direnvs:
    nix build .#direnv-shells --profile "{{ xdg_state_home }}/nix/profiles/direnv-shells"

# Search for a package in nixpkgs
search query *args:
    nh search {{ query }} {{ args }}

# Show detailed info about a package
info package:
    nix eval nixpkgs#{{ package }}.meta --json | nix run nixpkgs#jq -- -r '.'

# Show the build log for a package
log package *args:
    nix log {{ args }} nixpkgs#{{ package }}

# Show why a package is in the system closure
why package *args:
    nix why-depends {{ args }} {{ system-profile }} nixpkgs#{{ package }}

# Show the dependency tree for a package
deps package *args:
    nix path-info -rsSh {{ args }} nixpkgs#{{ package }}

# List system generations
generations:
    nix profile history --profile {{ system-profile }}

# Show flake inputs and their revisions
inputs *args:
    nix flake metadata {{ args }}

# Delete old generations and garbage collect
gc days="30":
    ./scripts/gc.bash "{{ days }}" "{{ xdg_state_home }}"

# Open a nix repl with the flake loaded
repl *args:
    nix repl {{ args }} .

# Format nix files
fmt *args:
    nix fmt {{ args }}

# Check the flake for errors
check *args:
    nix flake check --all-systems {{ args }}

# Lint: format and check the flake
lint: fmt check

# Show closure size of current system
size:
    nix path-info -sSh {{ system-profile }}

# Show closure size of all system generations
sizes:
    @for gen in /nix/var/nix/profiles/system-*-link; do \
        printf "%s\t" "$(basename "${gen}")"; \
        nix path-info -sSh "${gen}" | awk -F'\t' '{print $3}'; \
    done | sort -t- -k2 -n

# Show what changed between two generations (e.g. just diff 161 162)
diff gen1 gen2:
    nvd diff /nix/var/nix/profiles/system-{{ gen1 }}-link /nix/var/nix/profiles/system-{{ gen2 }}-link

# Show history of last n system generations
history n="1" *args:
    #!/usr/bin/env bash
    set -euo pipefail

    current=$(basename "$(readlink {{ system-profile }})" | grep -oE '[0-9]+')
    min=$((current - {{ n }}))
    nvd history -p {{ system-profile }} -m "${min}" {{ args }}

# Install NixOS on a remote target via nixos-anywhere
install host target keys_dir="" phases="":
    ./scripts/install.bash "{{ host }}" "{{ target }}" "{{ keys_dir }}" "{{ phases }}"

# Serve a PXE/netboot installer for a host using keys from ssh-agent

netboot host *args:
    ./scripts/netboot.bash "{{ host }}" {{ args }}

# Build an ISO installer image for a host
build-iso host:
    ./scripts/build-iso.bash "{{ host }}"

# Sync nixbuild.net's substituters and trusted public keys with this repo's shared cache configuration.
sync-nixbuild-substituters:
    ./scripts/sync-nixbuild-substituters.bash

# Install NixOS onto a locally-connected drive
install-local host device:
    @echo "Installing NixOS on {{ host }} to {{ device }}"
    sudo nix run github:nix-community/disko -- \
      --mode disko hosts/{{ host }}/disks.nix \
      --arg device '"{{ device }}"'
    sudo nixos-install --flake .#{{ host }} --root /mnt

# Build and run a NixOS VM for testing
vm host:
    nixos-rebuild build-vm --flake .#{{ host }}
    result/bin/run-*-vm

# Generate SSH host key and age keys into a directory
[private]
generate-keys host keys_dir:
    ./scripts/generate-keys.bash "{{ host }}" "{{ keys_dir }}"

# Prompt for a user passphrase, hash it, and encrypt with sops
[private]
generate-user-secrets host secrets_dir keys_dir:
    ./scripts/generate-user-secrets.bash "{{ host }}" "{{ secrets_dir }}" "{{ keys_dir }}"

# Generate secure boot PCR signing keys and encrypt with sops
[private]
generate-secureboot-secrets host secrets_dir:
    ./scripts/generate-secureboot-secrets.bash "{{ host }}" "{{ secrets_dir }}"

# Generate borgmatic encryption passphrase and encrypt with sops
[private]
generate-borgmatic-secrets host secrets_dir:
    ./scripts/generate-borgmatic-secrets.bash "{{ host }}" "{{ secrets_dir }}"

# Generate all keys and secrets for a new NixOS host
generate-host-keys host:
    ./scripts/generate-host-keys.bash "{{ host }}" "{{ secrets_repo }}"
