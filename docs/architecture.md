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

Each field takes a module, or a list of modules. Several files may define the
same field of the same feature; the definitions merge into one module.

A feature includes the features it depends on, and hosts get those too. Home
Manager content and includes can be scoped to one host OS under `os.<os>`:

```nix
# modules/git/default.nix
{
  flake.features.git = {
    homeManager = ./home-manager.nix;
    os = {
      darwin.homeManager = ./credential-darwin.nix;
      linux.homeManager = [./credential-linux.nix ./gitsign.nix];
      nixos.homeManager = [./credential-linux.nix ./gitsign.nix];
    };
  };
}

# profiles/adsb/default.nix
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

The features a host lists directly live in `profiles/<name>/default.nix`, and
the features those include live in `modules/<name>/default.nix`. Both
directories are discovered automatically, and only a `default.nix` one level
down is loaded, so helper files beside it are not modules.

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
| `lib/sops.nix`      | sops-nix module fragments                             |
| `lib/projects.nix`  | project shell / direnv generation                     |
