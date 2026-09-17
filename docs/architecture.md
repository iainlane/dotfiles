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
sets `flake.hosts.<name>`. A host with hardware or disk configuration of its own
is a directory, `hosts/<name>/default.nix`, and imports the files beside it from
its `systemModule`. The files are discovered automatically, so there is no list
to keep in sync.

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
the names of every feature on the host once includes are followed.

## Features

A feature is the configuration for one concern across the module systems that
build a host. It is registered under `flake.features.<name>` with one field per
module system, named after the module system that evaluates it:

| Field           | Evaluated by                                                        |
| --------------- | ------------------------------------------------------------------- |
| `nixos`         | NixOS                                                               |
| `darwin`        | nix-darwin                                                          |
| `systemManager` | system-manager, on Linux hosts that are not NixOS                   |
| `homeManager`   | Home Manager                                                        |
| `system`        | whichever of `nixos`, `darwin` and `systemManager` builds this host |

Each of those fields takes a module, or a list of modules. Several files may
define the same field of the same feature; the definitions merge into one
module.

A feature also has a `provides` field, which is not a module. It contains an
attribute set of child feature definitions. Declaring a child does not add it to
a host; a feature or host must include it explicitly.

A feature includes the features it depends on, and a host that lists it resolves
those as well. Two scopes narrow what a feature contributes. `os.<os>` takes a
Home Manager module and an `includes` list that apply only on hosts with that
OS, and `kernel.<linux|darwin>` takes a Home Manager module for every host with
that kernel:

```nix
# features/git/default.nix
{
  flake.features.git = {
    homeManager = ./home-manager.nix;
    kernel = {
      darwin.homeManager = ./home-manager-darwin.nix;
      linux.homeManager = [./home-manager-linux.nix ./gitsign.nix];
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

`nixos`, `darwin` and `systemManager` each imply an OS, so they need no OS
scoping. `system` is the exception: it goes to whichever of those three builds
the host.

`kernel.linux` covers NixOS as well as the Linux hosts system-manager builds,
which is why `git` above puts its Linux modules there. `os.nixos` and
`os."generic-linux"` are the two halves of that: a NixOS host takes nothing from
`os."generic-linux"`, and a system-manager host takes nothing from `os.nixos`.

### Top-level features and children

A feature is top-level when it is a concern a host composes in its own right,
such as `base` or `desktop`. Every other concern is a child of the feature it
belongs to, registered under that feature's `provides`. A child has every field
a feature has, including its own `provides`, and its name is qualified by its
parent's, so `base`'s zsh configuration is `base.zsh` and appears under that
name in `featureNames`.

Registering a child does not apply it. Something has to list it in `includes`,
so a parent lists the children that always apply and puts the conditional ones
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

A child that its parent includes must not include the parent: the resolver
reports that as a cycle. A child that something else selects must include the
features that declare the options it uses, which is why `ai.claude-desktop` and
`work.claude-managed-settings` both include `ai`.

Discovery loads `features/<name>/default.nix` and nothing else, so a file beside
it is loaded only when that `default.nix` imports it. A directory registers the
top-level feature of its own name, and may register others whose names extend
it: `features/nixbuild/default.nix` registers `nixbuild-substituter` and
`nixbuild-builder`. Module files are named after the module system they are for:
`nixos.nix`, `darwin.nix`, `system-manager.nix`, `home-manager.nix`, with
`home-manager-linux.nix` for the kernel scope and `home-manager-nixos.nix` or
`home-manager-generic-linux.nix` for the OS scope. Packages live under `pkgs/`,
even when one feature is their only consumer.

`lib/features.nix` resolves a host's feature list into the modules for one
module system. It expands includes depth-first, so a feature comes after the
features it includes. Each feature is emitted once, and an include cycle throws
an error naming the features in the cycle.
`flake/parts/checks/feature-resolution.nix` compares the resolver's module lists
with fixtures covering each of those.

`flake/parts/checks/feature-registration.nix` enforces the layout rules above.
It reads the file each definition of `flake.features` came from and fails when a
top-level feature is registered anywhere but the `default.nix` of the directory
its name belongs to, or when a file adds children to a feature outside that
directory.

## Options

Composition decides what a host runs. The module system is still where values
live, because that is where types, defaults, merging and error messages come
from, but a feature never asks a host to switch it on. A host switches a feature
on by including it. Six rules follow, and every option in this repository keeps
to them.

1. **Presence is the switch.** A feature or child never declares an `enable`
   that a host sets. A module written as an ordinary NixOS service module for a
   package keeps its own `enable` and the feature sets it, which is what
   `services.falcon-sensor` is.
2. **Every switch is a child feature.** A parent lists its default children in
   `includes`, and a host drops the ones it does not want through `excludes`. So
   `hermes` includes `signal`, `matrix`, `dashboard`, `homeassistant`, `soul`,
   `agents`, `mcp`, `embeddings` and `backup`; `caddy` includes `auth` and
   `origin-auth`; `agentsview-server` and `matrix` include `backup`. A child
   that is not a default, such as `ai.cloudflare-mcp`, is listed by whatever
   feature or host wants it, or under `os.<os>.includes`.
3. **Host values reach a feature through `hostConfig`.** No class module reads
   `config.flake.hosts`. A module body may call `hasFeature` when one feature's
   behaviour depends on another being present on the host, but it cannot decide
   an `includes` list, because includes are registry-level and no host is in
   scope there; the only host-dependent include is `os.<os>.includes`. A value
   more than one feature needs is a typed field of the host record (`name`,
   `hostname`, `os`, `arch`, `channel`, `stateVersion`, `motd`, `timezone`,
   `flakePath`). A value one feature needs is that feature's option, which the
   host sets in `systemModule` or `homeModule`. A feature's `secretsFile`
   defaults to `<hostConfig.name>/host-<feature>.yaml`. A child that shares its
   parent's secrets defaults to the parent's file, and a backup child defaults
   to `<hostConfig.name>/host-r2.yaml`. A host sets one only to deviate.
4. **One root for everything the repository declares.** Every option lives under
   `dotfiles.<declaring feature or child>`, camelCased. A switch child nests
   under its parent's root (`dotfiles.hermes.signal.*`,
   `dotfiles.caddy.auth.*`); every other child has a root of its own. Options
   that the flake-parts modules read, and that no host's class module sees, live
   under `flake.` (`flake.username`, `flake.operatingSystems`). The exceptions
   are modules that mirror an upstream module's shape and could be upstreamed as
   they are: `services.falcon-sensor`, `virtualisation.quadlet` and
   `virtualisation.containers.idRanges`.
5. **An option's value is data, not a function.** A function is a module
   argument. `exposePodman`, `serviceNetwork` and `mkLanguageShell` are set
   through `_module.args`.
6. **`readOnly` marks a derived value**, never a default a host might want to
   change.

### Excludes

followed, so a feature that nothing else includes is dropped with it. `closure`
returns the features in composition order and the names it dropped, and both
`featureNames` and the module list derive from it, so `hasFeature` and the
modules cannot disagree. Two kinds of entry are refused: a feature the host also
lists in `features`, and a feature the closure never reaches.

```nix
flake.hosts.example = {
  features = [features.base features.hermes];
  excludes = [features.hermes.provides.signal];
};
```

### Presence options

A parent often has to know which of its children a host composed: hermes adds
the signal network to the agent's container, its restore script stops the
dashboard before replacing the shared state, and Caddy refuses a site that asks
for sign-in when no sign-in service is there. The child publishes that by
defining one boolean the parent declares:

```nix
# features/hermes/options.nix, in the parent
signal.present = presence.option "the Signal platform, ...";

# features/hermes/signal/system-manager.nix, in the child
dotfiles.hermes.signal.present = true;
```

The parent declares it so the option exists even on a host that excludes the
child; there the parent reads `false`. `lib/presence.nix` defines the
declaration and an assertion that counts the files defining the option and
refuses more than one, so a host that sets it is told to change its composition.

The child declares its own settings, and the parent reads them only inside a
branch on the presence option, so they are never forced on a host without the
child. An option the parent reads while building something unconditionally stays
with the parent.

Where the parent needs a list or an attribute set, the child defines into an
option of that type that the parent declares, and the module system's merge
combines the definitions.

## OS adapters

For a given host, the features resolve to a flat list of modules for each module
system. The OS adapters in `os/<os>/default.nix` take that list and hand it to
the right system builder:

- `os/nixos` → `nixpkgs.lib.nixosSystem` (also embeds Home Manager, and grafts
  the unstable `lib.hm` onto stable hosts so unstable HM modules evaluate),
- `os/darwin` → `nix-darwin.lib.darwinSystem` (embeds Home Manager),
- `os/generic-linux` → `system-manager.lib.makeSystemConfig` (Home Manager is
  deployed standalone rather than embedded).

Shared plumbing (feature resolution, Home Manager assembly, the system special
arguments, sops fragments) lives in `lib/`, so each adapter owns only what its
system builder needs: the builder function, the modules it prepends, and how
Home Manager reaches the configuration.

## Flake outputs

The adapters feed the configuration outputs:

- `nixosConfigurations.<host>`: NixOS hosts,
- `darwinConfigurations.<host>`: nix-darwin hosts,
- `systemConfigs.<host>`: system-manager (non-NixOS Linux) hosts,
- `homeConfigurations.<user>@<host>`: standalone Home Manager for every host,
- `deploy`: the deploy-rs nodes, derived from the host set, so a host can be
  pushed with `deploy .#<host>`.

The rest of the flake is the tooling and the data other things read:

- `packages` and `apps`: what `pkgs/` builds, the tools re-exported from flake
  inputs, the per-host netboot installers, and one `update-<name>` app per
  updater,
- `checks` and `formatter`: what `nix flake check` and `nix fmt` run,
- `direnvs` and `devShells.direnvs-*`: per-directory development shells, and
  `packages.direnv-shells`, which builds them all,
- `cupboardOutputs` and `updaterNames`: the lists the cupboard publish and
  package update workflows iterate,
- `features`, `hosts`, `operatingSystems`, `username`, `direnvLanguages` and
  `nix`: the flake-parts options this repository declares, readable from a
  script that needs to know what is configured,
- `agentsviewHosts` and `agentsviewServer`: the hosts that push agent sessions
  and the server they push to, read by the secrets generator.

## Helper layout

`lib/` is split by responsibility, and each caller imports the file it needs:

| File                                 | Responsibility                                            |
| ------------------------------------ | --------------------------------------------------------- |
| `lib/channels.nix`                   | the nixpkgs and Home Manager pair for each host channel   |
| `lib/container-image.nix`            | images built from a Nix closure                           |
| `lib/discovery.nix`                  | filesystem discovery: hosts, features, packages, overlays |
| `lib/exposed-service.nix`            | the options declared by a service the proxy serves        |
| `lib/features.nix`                   | feature resolution: includes, ordering, class modules     |
| `lib/fetch-github-release-asset.nix` | a release asset from a private GitHub repository          |
| `lib/halls.nix`                      | the message of the day for each host                      |
| `lib/home.nix`                       | Home Manager modules and special arguments                |
| `lib/netboot/`                       | the PXE and ISO installers, and the netboot server        |
| `lib/nix/`                           | the shared cache settings and a pinned nixpkgs revision   |
| `lib/nixbuild.nix`                   | the nixbuild.net account constants, read by CI too        |
| `lib/operating-systems.nix`          | what varies by OS and is not code                         |
| `lib/presence.nix`                   | the option a child feature defines to say it is there     |
| `lib/project-directories/`           | the Home Manager module that writes the `.envrc` files    |
| `lib/projects.nix`                   | project shell and direnv generation                       |
| `lib/quadlet.nix`                    | typed container mounts and the auto-userns contract       |
| `lib/r2-backup.nix`                  | the backup and verify units for an R2 bucket              |
| `lib/r2.sh`                          | the backup, verify and restore script                     |
| `lib/sops.nix`                       | sops-nix module fragments                                 |
| `lib/system.nix`                     | the system special arguments                              |
