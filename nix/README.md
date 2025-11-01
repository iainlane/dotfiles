# Nix-Based Dotfiles

Declarative configuration for managing development environments across multiple
machines using Nix flakes, nix-darwin, system-manager, and home-manager.

## Overview

Nix flakes pin an entire package universe via `flake.lock`, which captures a
specific nixpkgs commit (~80,000 packages at known-good versions). This enables
atomic updates, perfect reproducibility across machines, binary caching, and
instant rollback.

## Architecture

The setup uses composable profiles as flake-parts modules. Each profile can
contribute home-manager configuration, direnv shells, and development
environments.

Auto-discovery: hosts are found in `hosts/*.nix`, profiles in
`profiles/*/default.nix`. No central inventory.

Direct composition: each host file explicitly specifies its profiles.

Self-contained modules: configuration files live alongside their module
definitions, using repository-relative paths.

Git identity handling: base profile sets defaults with `lib.mkDefault`, work
machines override with normal priority.

### Directory Structure

```text
nix/
├── flake.nix                 # Entry point
├── flake/parts/              # Modular flake-parts components
├── lib/                      # Helper functions
├── os/                       # OS-specific system config (darwin/linux)
├── profiles/                 # Composable profiles (base, desktop, cloud, etc.)
├── modules/                  # Program configurations (git, zsh, neovim, etc.)
└── hosts/                    # Per-host configurations
```

Each profile is a self-contained flake-parts module that can contribute:

- `homeManagerModules.${profileName}` - home-manager configuration
- `direnvs.${system}.*` - nested direnv shells (if defining projects)
- `devShells.${system}.direnvs-*` - flat devShells for `nix develop`

Profiles that define project directories contribute their own development
environments without centralized coordination. See `profiles/home/default.nix`
or `profiles/work/default.nix` for examples.

Example host configuration:

```nix
{
  hostname = "hostname.example.com";
  os = "linux";
  arch = "x86_64";
  profiles = [
    "base"
    "desktop"
    "development"
    "cloud"
    "work"
  ];

  homeModule = { ... }: {
    # Host-specific overrides
    programs.git.settings.user.email = "work@example.com";
  };
}
```

## Usage

### Initial Setup

Install Nix:

```bash
./bootstrap.sh
```

Or directly:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L \
  https://install.determinate.systems/nix | sh -s -- install
```

### Testing Before Deployment

Check syntax:

```bash
nix flake check
```

Build without activating:

```bash
nix build .#homeConfigurations.HOSTNAME.activationPackage
```

Dry-run:

```bash
./result/activate --dry-run
```

Back up existing dotfiles:

```bash
tar -czf ~/dotfiles-backup-$(date +%Y%m%d).tar.gz ~/.config ~/.zshenv
```

### Deployment

Local machine:

```bash
nix run home-manager/master -- switch --flake .#HOSTNAME
```

After first run:

```bash
home-manager switch --flake .#HOSTNAME
```

Remote hosts (deploy-rs with automatic rollback):

```bash
deploy                    # all hosts
deploy .#HOSTNAME         # specific host
```

### Updates

Update to latest nixpkgs-unstable:

```bash
nix flake update
```

Then deploy as usual.

### Rollback

List previous generations:

```bash
home-manager generations
```

Activate a previous generation:

```bash
/nix/var/nix/profiles/per-user/$USER/home-manager-XX-link/activate
```

Or rollback via git:

```bash
git checkout <commit-hash> flake.lock
home-manager switch --flake .#HOSTNAME
```

## Configuration

### Adding Packages

Find packages at [search.nixos.org](https://search.nixos.org) and add to
appropriate profile in `profiles/`:

- `base`: core tools
- `desktop`: GUI applications
- `development`: dev tools
- `cloud`: cloud SDKs
- `home` / `work`: project-specific tooling

### Adding Hosts

Create `hosts/HOSTNAME.nix`:

```nix
{
  hostname = "hostname.example.com";
  os = "darwin";  # or "linux"
  arch = "aarch64";  # or "x86_64"
  profiles = [
    "base"
    # other profiles
  ];

  # Optional host-specific overrides
  homeModule = { ... }: {
    programs.git.settings.user.email = "work@example.com";
  };
}
```

The flake discovers new hosts automatically.

### Modifying Configs

Git identity: edit `modules/git/default.nix` or override in host files.

Shell: edit files in `modules/zsh/`.

Neovim: edit files in `modules/neovim/nvim/`.

New programs: create a module in `modules/` and import in appropriate profile.

## Project Directories

The `home` and `work` profiles demonstrate automatic `.envrc` generation for
per-directory development environments. Profiles define projects with custom
environment variables (git identity, packaging config, etc.), and the system
generates direnv shells and flat devShells for `nix develop`.

Define projects in a profile's `default.nix`:

```nix
projects = let
  defaults = {
    name = "Iain Lane";
    debsignKeyId = "0xE352D5C51C5041D4";
  };
in {
  dev-debian = defaults // {
    directory = "dev/debian";
    email = "laney@debian.org";
    debVendor = "Debian";
    zshColour = "red";
  };
};
```

Define the shell builder to control environment variables:

```nix
mkShell = pkgs: def:
  pkgs.mkShell (
    {
      packages = def.packages or (_: []) pkgs;
    }
    // {
      NAME = def.name;
      EMAIL = def.email;
      GIT_AUTHOR_NAME = def.name;
      GIT_AUTHOR_EMAIL = def.email;
      DEBSIGN_KEYID = def.debsignKeyId;
    }
    // lib.optionalAttrs (def.debVendor != null) {
      DEB_VENDOR = def.debVendor;
    }
  );
```

The profile automatically contributes:

- `homeManagerModules.home` - configures `project-directories` module
- `direnvs.${system}.dev.debian` - nested shell for flake references
- `devShells.${system}.direnvs-dev-debian` - flat shell for `nix develop`

Home-manager generates `.envrc` files in each project directory that reference
the shells from the `direnvs` output. See `profiles/home/default.nix` or
`profiles/work/default.nix` for complete examples.

## Troubleshooting

Package not found: check [search.nixos.org](https://search.nixos.org). Some
packages have different names in nixpkgs (e.g., `yq` → `yq-go`).

Conflicts with existing dotfiles: home-manager will warn. Back up and remove
conflicting files.

Deployment fails: ensure SSH works and Nix is installed on remote hosts. Use
`deploy --debug-logs`.

Out of disk space: clean old generations with `nix-collect-garbage -d`.

## Scope

This manages both system and user-level configuration across macOS (via
nix-darwin) and Linux (via system-manager). It handles system preferences,
dotfiles, development tools, application configs, fonts, and deployment with
automatic rollback.

It does not manage NixOS-specific features, low-level system services
(networking, boot), or hardware-specific settings (drivers, kernel modules).
