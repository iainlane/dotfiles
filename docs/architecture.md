# Architecture

This repo is a [flake-parts] flake that produces NixOS, nix-darwin,
[system-manager], and [Home Manager] configurations for several machines from
one shared set of building blocks.

Hosts select features. The resolver composes their modules, OS adapters evaluate
host configurations, and the output evaluator exports the selected tooling.

[flake-parts]: https://flake.parts
[system-manager]: https://github.com/numtide/system-manager
[Home Manager]: https://nix-community.github.io/home-manager/

## Hosts

A host is one machine. Each file under `hosts/` is a flake-parts module that
sets `flake.hosts.<name>`. A host with hardware or disk configuration of its own
is a directory, `hosts/<name>/default.nix`, and imports the files beside it from
its `systemModule`. The files are discovered automatically, so there is no list
to keep in sync.

A host declares its OS and architecture, its features, and any configuration
that applies to this host alone:

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
declares options in the module system that it configures, and the host sets
those options through `systemModule` or `homeModule`, where the module system
checks them.

The `flake.hosts` option (in `flake/parts/hosts.nix`) types these records and
computes derived fields such as `system`, `homeDirectory` and `featureNames`,
the names of every feature on the host once includes are followed.

## Features

A feature is registered under `flake.features.<name>`. It contributes modules to
classes from the registry in `lib/feature-classes.nix`:

| Class            | Evaluation                                              |
| ---------------- | ------------------------------------------------------- |
| `nixos`          | NixOS                                                   |
| `darwin`         | nix-darwin                                              |
| `systemManager`  | system-manager                                          |
| `homeManager`    | Home Manager                                            |
| `system`         | Alias for the host's primary configuration class        |
| `packages`       | Packages exported under `packages.<system>`             |
| `apps`           | Applications exported under `apps.<system>`             |
| `checks`         | Checks exported under `checks.<system>`                 |
| `devShells`      | Shells exported under `devShells.<system>`              |
| `legacyPackages` | Nested outputs exported under `legacyPackages.<system>` |

Each class accepts a module, a path, or a list of modules and paths. Definitions
from several files merge, and errors retain the source file of each definition.
`system` uses the destination from the OS metadata; the resolver has no separate
traversal for that alias.

### Conditional composition

Features include other features by value. Included features precede their
parent, and each registered feature is resolved once. A reference to an unknown
feature fails at the reference. An include cycle reports the features in the
cycle.

Use `featureResolver.when` for conditional composition. An include can also be
an inline fragment with class fields and its own includes:

```nix
{featureResolver, ...}: let
  inherit (featureResolver) when isLinux isDarwin;
in {
  flake.features.git = {
    homeManager = ./home-manager.nix;
    includes = [
      (when isLinux [{homeManager = [./home-manager-linux.nix ./gitsign.nix];}])
      (when isDarwin [{homeManager = ./home-manager-darwin.nix;}])
    ];
  };
}
```

There are no `os` or `kernel` fields. The same composition mechanism applies to
all classes. Fragment modules precede the module of their parent, just as other
includes do. Use native module ordering and priorities when values need explicit
ordering or overrides.

The resolver constructs `platform` with `lib.systems.elaborate system`.
Selection does not instantiate a package set. Host contexts also contain
`hostConfig` and `systemClass`. Helpers are available directly on
`featureResolver`: `isLinux`, `isDarwin`, `isNixos`, `isGenericLinux`,
`isAarch64`, `isx86_64`, `isStable` and `isUnstable`.

A predicate runs only when its required arguments exist in the selection
context. For example, `isGenericLinux` is skipped during shared output
selection, because that context has a platform but no host. Selection cannot
depend on evaluated system or Home Manager settings.

`when` also accepts a feature or a list of features. The condition succeeds when
all those features are selected. A custom predicate receives `hasFeature`:

```nix
includes = [
  (when features.ai [features.ai.provides.claude-code.provides.teamclaude])
  (when ({hasFeature, ...}: hasFeature features.git) [children.gitTools])
];
```

The resolver repeats selection until membership stops changing. Each walk tests
membership from the preceding walk, so the order of roots does not determine
which conditions succeed. Predicates that cause membership to oscillate fail
with an error.

### Registered children and inline fragments

A feature registers independently selectable concerns under `provides`. A child
has all feature fields and can register children of its own. Its qualified name,
such as `base.zsh`, appears in `featureNames` and works with `hasFeature`,
`when` and `excludes`. Registering a child does not select it.

```nix
{config, featureResolver, ...}: let
  inherit (config.flake) features;
  children = features.base.provides;
  inherit (featureResolver) when isNixos;
in {
  imports = [./zsh ./openssh ./restic];
  flake.features.base = {
    includes = [children.zsh (when isNixos [children.openssh children.restic])];
    homeManager = ./home-manager.nix;
  };
}
```

Conditional selection keeps OS-specific children out of `featureNames` on other
hosts, even if their class already implies the OS. A child that its parent
includes cannot include the parent.

Inline fragments group conditional modules that do not need a separate switch.
They have deterministic internal identities derived from their owner and list
position. Those identities deduplicate contributions but do not appear in
`featureNames`. Use a registered child when callers need to select, exclude or
test membership of the concern independently.

Discovery loads `features/<name>/default.nix`. That module explicitly imports
files beside it. Checks and other outputs have no separate discovery mechanism.
A directory registers its own top-level feature and any related features whose
keys extend the directory's key, such as `nixbuild-builder` under `nixbuild`.
`feature-registration` checks this layout.

Configuration modules retain their existing filenames, such as `nixos.nix`,
`home-manager-linux.nix` and `home-manager-generic-linux.nix`. Packages remain
under `pkgs/`. Feature-owned output modules belong beside the feature;
repository and package invariants remain under `flake/parts/checks/`.

### Output evaluation

Output selection and evaluation are separate. `flake.outputFeatures` explicitly
selects shared output roots for every supported system. `flake.outputExcludes`
excludes features from that selection. These roots preserve standalone tooling
coverage when no host on a system selects the feature.

The evaluator also collects contributions from each selected host graph under
that host's system. Shared contributions are deduplicated by feature, class and
contribution identity across roots and hosts. A host exclusion affects that
host's graph; another host or a shared root can still select shared outputs.

An ordinary output module receives the usual evaluation arguments:

```nix
checks = {pkgs, ...}: {
  parser = pkgs.runCommandLocal "parser-test" {} "touch $out";
};
```

A context-dependent output uses two functions. The outer function selects or
binds composition values; the inner function is an ordinary module:

```nix
checks = {hostConfig, systemConfig}: {pkgs, ...}: {
  "host-evaluation-parser-${hostConfig.name}" =
    builtins.deepSeq systemConfig.services.example
      (pkgs.runCommandLocal "parser-config-test" {} "touch $out");
};
```

The composition arguments are `platform`, `hostConfig`, `systemConfig` and
`homeConfig`. The last two are lazy evaluated `.config` values. The binder
passes only the composition arguments requested by the outer function. A flat
function such as `{hostConfig, pkgs, ...}:` therefore fails with Nix's normal
missing argument error. The inner `config` refers to the current output class.

A module requesting only `platform` is shared per system. Requesting any host
argument makes the contribution specific to each selected host. Shared output
modules use the overlaid unstable package set; host-bound modules use the host's
selected channel. Authors choose public output keys, including host qualifiers.
The evaluator adds no prefixes. Host checks that read private configuration use
`host-evaluation-`. The public CI export excludes checks with that prefix.

Each class is evaluated separately for the shared context and each host context.
`packages`, `apps`, `checks` and `devShells` use flake-parts' native option
types, including validation, defaults, module priorities and ordering. The
evaluator then merges those results with the same types. Conflicting definitions
fail. `legacyPackages` recursively merges attribute sets, concatenates lists in
module order, accepts equal leaves and rejects conflicting leaves. Derivations
are opaque leaves.

The resolver and evaluator fixtures cover selection, contexts, merging and
provenance. The host evaluation checks force each selected configuration's
top-level derivation without building the host.

### Project shells

`lib/projects.nix` returns a Home Manager module and modules for `devShells` and
`legacyPackages`. Flat `devShells.direnvs-*` keys provide `nix develop` entry
points. `legacyPackages.<system>.direnvs` contains the nested directory tree;
`direnvs.<system>` derives from that tree for existing `.envrc` consumers.

Language definitions contain a `fragments` list of `pkgs: attrs` functions and
`when` groups. The language helper uses the same context, predicates and
conditional-list selector as feature composition. It concatenates `packages` and
`shellHook` values while later fragments override other shell attributes.

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
   `includes`, and a host drops unwanted children through `excludes`. So
   `hermes` includes `signal`, `matrix`, `dashboard`, `homeassistant`, `soul`,
   `agents`, `mcp`, `embeddings` and `backup`; `caddy` includes `auth` and
   `origin-auth`; `agentsview-server` and `matrix` include `backup`. A child
   that is not a default, such as `ai.cloudflare-mcp`, is listed by whatever
   feature or host wants it, or through a conditional include.
3. **Host values reach a feature through `hostConfig`.** No class module reads
   `config.flake.hosts`. A module body may call `hasFeature` when one feature's
   behaviour depends on another being present on the host, but it cannot decide
   an `includes` list, because includes are registry-level and no host is in
   scope there. Conditional includes use the selection context and `hasFeature`;
   they cannot read evaluated system or home settings. A value more than one
   feature needs is a typed field of the host record (`name`, `hostname`, `os`,
   `arch`, `channel`, `stateVersion`, `motd`, `timezone`, `flakePath`). A value
   one feature needs is that feature's option, which the host sets in
   `systemModule` or `homeModule`. A feature's `secretsFile` defaults to
   `<hostConfig.name>/host-<feature>.yaml`. A child that shares its parent's
   secrets defaults to the parent's file, and a backup child defaults to
   `<hostConfig.name>/host-r2.yaml`. A host sets one only to deviate.
4. **One root for every option in the repository.** Every option lives under
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
6. **`readOnly` marks a derived value.** If a host might want to change an
   option's default, the option is not read-only.

### Excludes

`flake.hosts.<name>.excludes` lists the features that the resolver drops from
that host's closure. A dropped feature contributes no modules and its own
includes are not followed, so a feature that nothing else includes is dropped
with it. `closure` returns the features in composition order together with the
dropped names, and both `featureNames` and the module list derive from it, so
`hasFeature` and the modules cannot disagree. Two kinds of entry are refused: a
feature the host also lists in `features`, and a feature the closure never
reaches.

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
defining a boolean that the parent has declared:

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
child. If the parent reads an option while building something unconditionally,
that option stays with the parent.

Where the parent needs a list or an attribute set, the child defines into an
option of that type that the parent declares, and the module system's merge
combines the definitions.

## OS adapters

For a given host, the features resolve to a flat list of modules for each module
system. The OS adapters in `os/<os>/default.nix` take that list and hand it to
the right system builder:

- `os/nixos` uses `nixpkgs.lib.nixosSystem` (also embeds Home Manager, and
  grafts the unstable `lib.hm` onto stable hosts so unstable HM modules
  evaluate),
- `os/darwin` uses `nix-darwin.lib.darwinSystem` (embeds Home Manager),
- `os/generic-linux` uses `system-manager.lib.makeSystemConfig` (Home Manager is
  built and deployed separately).

Shared plumbing (feature resolution, Home Manager assembly, the system special
arguments, sops fragments) lives in `lib/`, so each adapter owns only what its
system builder needs: the builder function, the modules to prepend, and how Home
Manager reaches the configuration. The shared host result contains the system
configuration, its top-level derivation, the standalone Home Manager
configuration, class and output metadata, home arguments and the deployment
profile constructor. Output contexts, evaluation checks and deployment use this
result. OS dispatch remains in the adapters.

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
- `legacyPackages.<system>.direnvs`, `direnvs` and `devShells.direnvs-*`:
  per-directory development shells, and `packages.direnv-shells`, which builds
  them all,
- `cupboardOutputs` and `updaterNames`: the lists the cupboard publish and
  package update workflows iterate,
- `features`, `hosts`, `operatingSystems`, `username`, `direnvLanguages`,
  `outputFeatures`, `outputExcludes`, `modelCatalog` and `nix`: the flake-parts
  options declared in this repository, readable from a script that needs to know
  what is configured,
- `agentsviewHosts` and `agentsviewServer`: the hosts that push agent sessions
  and their destination server, read by the secrets generator.

## Helper layout

`lib/` is split by responsibility, and each caller imports the file that it
needs:

| File                        | Responsibility                                            |
| --------------------------- | --------------------------------------------------------- |
| `lib/channels.nix`          | the nixpkgs and Home Manager pair for each host channel   |
| `lib/container-image.nix`   | images built from a Nix closure                           |
| `lib/discovery.nix`         | filesystem discovery: hosts, features, packages, overlays |
| `lib/exposed-service.nix`   | the options declared by a proxied service                 |
| `lib/feature-classes.nix`   | configuration classes, output classes and aliases         |
| `lib/feature-outputs.nix`   | output collection, context binding and class evaluation   |
| `lib/features.nix`          | feature resolution: includes, ordering, class modules     |
| `lib/halls.nix`             | the message of the day for each host                      |
| `lib/home.nix`              | Home Manager modules and special arguments                |
| `lib/netboot/`              | the PXE and ISO installers, and the netboot server        |
| `lib/nix/`                  | the shared cache settings and a pinned nixpkgs revision   |
| `lib/nixbuild.nix`          | the nixbuild.net account constants, read by CI too        |
| `lib/operating-systems.nix` | what varies by OS and is not code                         |
| `lib/presence.nix`          | the option a child feature defines to say it is there     |
| `lib/project-directories/`  | the Home Manager module that writes the `.envrc` files    |
| `lib/projects.nix`          | project shell and direnv generation                       |
| `lib/quadlet.nix`           | typed container mounts and the auto-userns contract       |
| `lib/r2-backup.nix`         | the backup and verify units for an R2 bucket              |
| `lib/r2.sh`                 | the backup, verify and restore script                     |
| `lib/sops.nix`              | sops-nix module fragments                                 |
| `lib/system.nix`            | the system special arguments                              |
