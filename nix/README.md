# Nix-Based Dotfiles

Declarative configuration for managing development environments across multiple
machines using Nix flakes, nix-darwin, system-manager, and home-manager.

## Overview

This repository defines your entire development environment as code. Instead of
manually installing packages and editing config files, you describe what you
want and Nix makes it happen reproducibly.

The `flake.lock` file pins exact versions of every package (~80,000 available).
This means:

- Same versions on every machine
- Rebuild the exact same environment months later
- Roll back instantly if something breaks
- Share binary caches so you rarely compile from source

## Key Concepts

If you're new to Nix, here's what the terminology means:

**Flake**: A Nix project with declared dependencies. `flake.nix` is the entry
point; `flake.lock` pins exact versions.

**nixpkgs**: The package repository. Contains ~80,000 packages and NixOS
modules.

**home-manager**: Manages dotfiles and user packages declaratively. Instead of
editing `~/.zshrc` directly, you define it in Nix and home-manager generates it.

**nix-darwin**: Like NixOS modules, but for macOS. Manages system preferences,
launch agents, and Homebrew packages.

**system-manager**: Applies NixOS-style configuration to non-NixOS Linux. Lets
us use the same patterns on Ubuntu/Debian/etc.

**Module**: A Nix file that contributes configuration. Modules get merged
together; you can override values using priority functions like `lib.mkDefault`.

**Profile**: In this repo, a bundle of related configuration (base tools,
desktop apps, cloud SDKs). Hosts pick which profiles they want.

**Derivation**: Nix's term for "something that gets built". Packages, config
files, and shells are all derivations.

**flake-parts**: A library for structuring large flakes. Lets us split
configuration across files in `flake/parts/`.

## Architecture

The configuration is organised around profiles - bundles of related settings and
packages. Each machine picks which profiles it needs, and the system composes
them together.

To add a new machine: drop a file in `hosts/`, list the profiles it should
have, and run `home-manager switch`.

Hosts come from `hosts/*.nix`, profiles from `profiles/*/default.nix` - no
central inventory to maintain. Each host file explicitly lists its profiles.
Config files live alongside their module definitions. The base profile sets
defaults with `lib.mkDefault`; hosts or other profiles can override with normal
priority.

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

Run flake checks (formatting/lints/build checks):

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

Local machine (bootstraps home-manager if needed):

```bash
nix run home-manager/master -- switch --flake .#HOSTNAME
```

After first run:

```bash
home-manager switch --flake .#HOSTNAME
```

Remote hosts (deploy-rs with automatic rollback; requires deploy-rs in PATH):

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

Different projects often need different identities and tools. When contributing
to Debian you might use `laney@debian.org`; for work, `iain@company.com`. This
system automatically switches your git identity (and other settings) when you
`cd` into a project directory.

You define projects in a profile (see `profiles/home/default.nix`), the system
generates `.envrc` files in each project directory, and when you enter the
directory [direnv] loads a Nix shell with the right environment variables. Your
git commits then use the correct identity automatically.

Here's how to define projects in a profile's `default.nix`:

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

Then define a shell builder that turns each project definition into a Nix shell
with the right environment variables. The `//` operator merges attrsets (like
object spread in JavaScript):

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
the shells from the `direnvs` output in this flake. See
`profiles/home/default.nix` or `profiles/work/default.nix` for complete
examples.

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

[direnv]: https://direnv.net/
