# Architecture

This repo is a [flake-parts] flake that produces NixOS, nix-darwin,
[system-manager], and [Home Manager] configurations for several machines from
one shared set of building blocks.

The data flows in one direction:

```text
host  →  features  →  OS adapter  →  flake outputs
```

Each stage is described below.

[flake-parts]: https://flake.parts
[system-manager]: https://github.com/numtide/system-manager
[Home Manager]: https://nix-community.github.io/home-manager/

## Hosts

A host is one machine. Each file under `hosts/` is a flake-parts module that
sets `flake.hosts.<name>`. A NixOS host is a directory,
`hosts/<name>/default.nix`, because the NixOS adapter imports `hardware.nix` and
`disks.nix` from beside it. The files are discovered automatically, so there is
no list to keep in sync.

A host declares its OS and architecture, the features it has, and any
configuration that applies to this host alone:

```nix
{config, ...}: let
  inherit (config.flake) features;
in {
  flake.hosts.example = {
    hostname = "example.local";
    os = "generic-linux"; # or "nixos" / "darwin"
    arch = "x86_64";
    motd = "Welcome to example";
    features = [features.base features.desktop features.nixbuild-builder];

    # Settings for this host only. `systemModule` goes to whichever of NixOS,
    # nix-darwin or system-manager builds the host; `homeModule` goes to Home
    # Manager.
    homeModule = {
      dotfiles.nixbuild.admin = true;
      programs.git.settings.user.email = "me@example.com";
    };
  };
}
```

Features are referenced by value, so a feature that does not exist is an
evaluation error at the reference. A feature that takes per-host settings
declares options in the module system it configures, and the host sets those
options through `systemModule` or `homeModule`, where the module system checks
them.

The `flake.hosts` option (in `flake/parts/hosts.nix`) types these records and
computes derived fields such as `system`, `homeDirectory` and `featureNames`,
the names of every feature the host has once includes are followed.

## Features

A feature is the configuration for one concern across the module systems that
build a host. It is registered under `flake.features.<name>` with one field per
module system, named after the module system that evaluates it:

| Field           | Evaluated by                                      |
| --------------- | ------------------------------------------------- |
| `nixos`         | NixOS                                             |
| `darwin`        | nix-darwin                                        |
| `systemManager` | system-manager, on Linux hosts that are not NixOS |
| `homeManager`   | Home Manager                                      |
| `system`        | whichever of the first three builds the host      |
| `provides`      | features this one carries, applied when included  |

Each field takes a module, or a list of modules. Several files may define the
same field of the same feature; the definitions merge into one module.

A feature includes the features it depends on, and hosts get those too. Home
Manager content and includes can be scoped to one host OS under `os.<os>`, and
Home Manager content that is the same on every Linux host, NixOS included, to
one kernel under `kernel.<linux|darwin>`:

```nix
# features/git/default.nix
{
  flake.features.git = {
    homeManager = ./home-manager.nix;
    os = {
      darwin.homeManager = ./home-manager-darwin.nix;
      "generic-linux".homeManager = [./home-manager-linux.nix ./gitsign.nix];
      nixos.homeManager = [./home-manager-linux.nix ./gitsign.nix];
    };
  };
}

# features/adsb/default.nix
{config, ...}: {
  flake.features.adsb = {
    includes = [config.flake.features.containers];
    systemManager = {config, pkgs, ...}: {
      imports = [./options.nix];
      # ...
    };
  };
}
```

The system classes need no OS scoping because each one already implies an OS.

### Top-level features and children

A feature is top-level when a host lists it or when another feature includes it
because it depends on that feature's options. Every other concern is a child of
the feature that carries it, registered under that feature's `provides`. A child
has every field a feature has, including its own `provides`, and its name is
qualified by its parent's, so `base`'s zsh configuration is `base.zsh` and
appears under that name in `featureNames`.

Registering a child does not apply it. Something has to list it in `includes`,
so a parent names the children it always carries and puts the conditional ones
under `os.<os>.includes`:

```nix
# features/base/default.nix
{config, ...}: let
  inherit (config.flake) features;
  children = features.base.provides;
in {
  imports = [./zsh ./neovim ./nix ./sudo ./openssh ./restic];

  flake.features.base = {
    includes = with children; [zsh neovim nix sudo features.git];
    os.nixos.includes = with children; [restic openssh];
    homeManager = ./home-manager.nix;
  };
}

# features/base/zsh/default.nix
{
  flake.features.base.provides.zsh = {
    homeManager = ./home-manager.nix;
    os."generic-linux".homeManager = ./home-manager-linux.nix;
  };
}
```

A child with only system-class fields is still scoped under `os.<os>.includes`,
although its class already implies the OS: the scope is what keeps the child out
of `featureNames` on the other OSes, so `hasFeature` never claims
`desktop.gnome` on a darwin host.

A child its parent includes must not include the parent, which the resolver
reports as a cycle. A child the parent does not include has to bring whatever
declares the options it uses: `ai.claude-desktop` and
`work.claude-managed-settings` both include `ai` for that reason.

Every feature lives in `features/<name>/default.nix`. The directory is
discovered automatically, and only a `default.nix` one level down is loaded, so
helper files beside it are not modules. Module files are named after the module
system they are for: `nixos.nix`, `darwin.nix`, `system-manager.nix`,
`home-manager.nix`, with `home-manager-linux.nix` for the kernel scope and
`home-manager-nixos.nix` or `home-manager-generic-linux.nix` for the OS scope.
Packages live under `pkgs/`, even when one feature is their only consumer.

`lib/features.nix` resolves a host's feature list into the modules for one
module system. It expands includes depth-first, so a feature comes after the
features it includes, emits each feature once, and reports an include cycle by
naming it. The check in `flake/parts/checks/feature-resolution.nix` pins that
behaviour against fixtures.

## OS adapters

For a given host, the features resolve to a flat list of modules for each module
system. The OS adapters in `os/<os>/default.nix` take that list and hand it to
the right system builder:

- `os/nixos` → `nixpkgs.lib.nixosSystem` (also embeds Home Manager, and grafts
  the unstable `lib.hm` onto stable hosts so unstable HM modules evaluate),
- `os/darwin` → `nix-darwin.lib.darwinSystem` (embeds Home Manager),
- `os/generic-linux` → `system-manager.lib.makeSystemConfig` (Home Manager is
  deployed standalone rather than embedded).

Shared plumbing (feature resolution, Home Manager assembly, sops fragments)
lives in `lib/` so the three adapters only own the parts that genuinely differ
between the system builders.

## Flake outputs

The adapters feed the flake outputs:

- `nixosConfigurations.<host>` — NixOS hosts,
- `darwinConfigurations.<host>` — nix-darwin hosts,
- `systemConfigs.<host>` — system-manager (non-NixOS Linux) hosts,
- `homeConfigurations.<user>@<host>` — standalone Home Manager for every host,
- `direnvs` / `devShells.direnvs-*` — per-directory development shells,
- `cupboardOutputs` — the flattened build matrix consumed by the cache-publish
  workflow.

`deploy` (deploy-rs) nodes are derived from the host set so each host can be
pushed with `deploy .#<host>`.

## Helper layout

`lib/` is split by responsibility; `lib/helpers.nix` is a thin aggregator that
wires the pieces together and re-exports the stable surface the rest of the
flake imports as `helpers`:

| File                | Responsibility                                        |
| ------------------- | ----------------------------------------------------- |
| `lib/discovery.nix` | filesystem discovery (hosts/features/pkgs)            |
| `lib/features.nix`  | feature resolution: includes, ordering, class modules |
| `lib/home.nix`      | Home Manager module + `specialArgs` assembly          |
| `lib/nixbuild.nix`  | the nixbuild.net account constants, read by CI too    |
| `lib/sops.nix`      | sops-nix module fragments                             |
| `lib/projects.nix`  | project shell / direnv generation                     |
