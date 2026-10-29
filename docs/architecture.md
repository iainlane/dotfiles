# Architecture

The flake composes named components, host declarations and package definitions.
The internal configuration is under `dotfiles`; public flake outputs expose
builds, commands and the metadata required by external consumers.

## Component ownership

Host-selectable concerns live under `features/`. Framework modules live under
`flake/`. Each immediate child directory has a `default.nix` entry point. The
flake automatically imports these entry points. Each component explicitly
imports its helpers and child entry points.

A host feature owns its configuration, outputs and tests. Framework modules own
composition, host assembly, Nix policy, package discovery, updates, CI,
formatting, Git hooks, deployment and installers. They export native flake-parts
outputs and checks without registering as host features.

Composition code belongs to `flake/composition`. Domain-specific checks stay
with their feature or package. Shared backup-library checks belong to the backup
integration module.

## Features

Register a host feature under `dotfiles.features.<name>`:

```nix
{config, ...}: {
  dotfiles.features.example = {
    homeManager = ./home-manager.nix;
    checks = ./checks.nix;
  };

  dotfiles.flakeSystem.includes = [config.dotfiles.features.example];
}
```

A feature can contribute modules to these classes:

| Class                                                       | Evaluation context                                   |
| ----------------------------------------------------------- | ---------------------------------------------------- |
| `nixos`                                                     | NixOS configuration                                  |
| `darwin`                                                    | nix-darwin configuration                             |
| `systemManager`                                             | system-manager configuration                         |
| `homeManager`                                               | Home Manager configuration                           |
| `system`                                                    | The host's primary OS configuration class            |
| `inventory`                                                 | Typed host declarations before runtime configuration |
| `packages`, `apps`, `checks`, `devShells`, `legacyPackages` | Flake output modules                                 |

Class contributions accept a module or a list of modules. Definitions from
several files merge with source provenance. The `system` alias targets `nixos`,
`darwin` or `systemManager` according to the host's OS.

### Children and includes

Direct attributes define independently selectable child features:

```nix
{config, ...}: {
  dotfiles.features.example = {
    includes = [config.dotfiles.features.example.shell];
    shell.homeManager = ./shell.nix;
    editor.homeManager = ./editor.nix;
  };
}
```

Selecting `example` applies `example.shell`. Selecting `example.editor` applies
that child alone. Registering a child does not select it or its parent.

Class keys and the control fields `name` and `includes` have their declared
meanings. Other keys define child features. `provides` has no special meaning;
it is available as an ordinary child key.

Top-level registrations belong in their owner's `default.nix`. Child
contributions belong within that owner's directory. Paired roots such as
`agentsview` and `agentsview-server` may share an owner. The registration check
uses module definition provenance to enforce these rules without evaluating
module bodies.

### Conditional composition

`featureResolver.when` accepts a feature, a list of features or a context
predicate:

```nix
{config, featureResolver, ...}: {
  dotfiles.features.example.includes = [
    (featureResolver.when featureResolver.isLinux [{homeManager = ./linux.nix;}])
    (featureResolver.when config.dotfiles.features.ai [
      config.dotfiles.features.example.agent-tools
    ])
  ];
}
```

Predicates may inspect platform, OS, channel and selected-feature membership.
Resolution follows includes in order, applies exclusions and deduplicates named
features. Includes precede their parent. Cycles and unstable conditional
selections fail evaluation.

Inline fragments contribute class modules without adding public feature
membership. Their identities follow their owner and include position.

## Hosts

A file under `hosts/` declares a typed host record:

```nix
{config, ...}: {
  dotfiles.hosts.example = {
    os = "generic-linux";
    arch = "x86_64";
    features = [config.dotfiles.features.base];
    homeModule.programs.git.settings.user.email = "user@example.com";
  };
}
```

A host with hardware or disk modules can use `<name>/default.nix`. Its record
specifies OS, architecture, channel, feature selection, exclusions and local
configuration modules. Derived fields include the system string and resolved
feature names. The host schema and assembly belong to `host-assembly`.

`excludes` removes a reached feature and its own includes. Excluding a directly
listed feature or a feature outside the selection is an error. Other includes
may still select dependencies of an excluded feature.

OS adapters instantiate NixOS, nix-darwin or system-manager. Shared helpers
build Home Manager modules and special arguments for both standalone and
embedded configurations. Stable hosts retain stable primary package sets and
receive the explicit unstable package set for integrations that require it.

## Shared evaluation contexts

Expensive system-wide values belong in `perSystem._module.args`. Flake-parts
shares each system's evaluation, and the framework exposes its arguments as
`flakeContext` for the current system and `flakeContexts.${system}` for another
system. These arguments are available in native `perSystem` modules, every OS
adapter, standalone and embedded Home Manager configurations, and all feature
output classes. Feature selection and inventory remain independent of package
contexts.

A provider constructs a value once:

```nix
perSystem = {pkgs, ...}: {
  _module.args.registry = import ./registry.nix {inherit pkgs;};
};
```

A consumer requests `flakeContext` or `flakeContexts` in its module arguments,
then selects the shared value:

```nix
registry = flakeContext.registry;
guestPkgs = flakeContexts.aarch64-linux.pkgs;
```

The shared contexts contain the canonical unstable `pkgs`, stable `pkgs-stable`,
channel-specific `mcpByChannel`, `mcpRegistry` and `deployRs`. A runtime
module's ordinary `pkgs` still follows its host's channel. Package sets with
different pins, overlays or Nixpkgs configuration are distinct resources.
Providers must preserve those distinctions, with explicit variant keys when
necessary.

Selecting a resource leaves unrelated resources unevaluated. Register evaluated
values, not factories that every consumer calls again: Nix shares a value's
evaluation but does not memoise arbitrary function applications. Host-specific
configurations and fixtures with different inputs still require separate module
evaluations.

This follows Den's use of [shared resolution values] and [context injection].
Den leaves [package-set reuse] to the configuration. Our adapters already pass
shared packages explicitly and enable Home Manager's `useGlobalPkgs`.

[shared resolution values]:
  https://github.com/denful/den/blob/0f7675b0b789eabe1a62f8a31b5323a7ad3ca5c4/nix/lib/entities/_types.nix#L143-L168
[context injection]:
  https://github.com/denful/den/blob/0f7675b0b789eabe1a62f8a31b5323a7ad3ca5c4/modules/aspects/batteries/flake-parts/inputs.nix
[package-set reuse]: https://den.denful.dev/guides/nixpkgs/

## Inventory

`dotfiles.inventorySchema` declares typed data available to every host's
inventory evaluation. Selected features contribute ordinary Nix modules through
`inventory`; the host's `inventoryModule` supplies local overrides.

The evaluator resolves the feature graph first, evaluates each inventory and
then aggregates declarations across all systems. Inventory evaluation receives
host declaration context. It does not receive runtime system configuration, Home
Manager configuration or the global aggregate. Inventory values do not change
feature selection.

Runtime modules receive their host's inventory through `hostInventory`.
Components can aggregate `hostInventories` into their own typed models.

### AgentsView

AgentsView declares ordinary archives, additional publishers and an optional
server. Work contributes the ordinary archive's local-only policy. Hermes
contributes its independently selected publisher. Shared identity and credential
paths are configured in inventory and forwarded into runtime options.

The normalised topology supplies client configuration, server roles and trust,
embedding requirements and provisioning. Local-only archives need no server;
shared publishers require one server. Multiple servers are rejected. A server
does not need a local user archive.

Provisioning includes desired identities before credentials exist. Optional
server enrolment requires its certificate and password; watcher activation also
requires its private-key entry. The generated provisioning app contains a plan
of paths and identifiers. It does not contain credentials or evaluate runtime
configurations. Certificate writes use an explicit editable checkout path.

## Output collection

`dotfiles.flakeSystem.includes` selects shared components once per supported
system. Each feature declares its shared inclusion beside its output modules.
Hosts independently contribute outputs from their selected features. Framework
modules export native `perSystem` outputs directly; they do not enter the
feature registry or require a shared feature selection.

Ordinary output modules receive `pkgs`, `pkgs-stable`, `system`, `inputs` and
standard module arguments. A context-dependent contribution has an outer
function:

```nix
{
  checks = {hostConfig, homeConfig}: {pkgs, ...}: {
    "example-${hostConfig.name}" = pkgs.runCommandLocal "example" {} ''
      test -n ${pkgs.lib.escapeShellArg homeConfig.home.username}
      touch "$out"
    '';
  };
}
```

Contributions requesting `hostConfig`, `systemConfig` or `homeConfig` are
evaluated for actual hosts on their native systems. Shared contributions are
evaluated against unstable packages and deduplicated by feature identity. Owners
capture other dependencies explicitly in check factories; a check's `config` and
`options` refer to the check-class module system.

Use the [assertion-check constructor] for evaluation-time assertions. It accepts
an `assertions` list with `assertion` and `message` attributes, and an optional
build `script`. Scheduling metadata stays available without evaluating the
assertions; requesting `drvPath` evaluates them. The constructor uses a trivial
builder with no required system features. VM tests keep their own feature
metadata.

[assertion-check constructor]: ../lib/assertion-check.nix

Packages, apps, checks and development shells use flake-parts' native output
types. Legacy packages recursively merge attribute sets, concatenate lists and
reject conflicting scalar values. Specialised adapters project host
configurations, deployment, formatter and installer outputs beside their owners.

### Project shells

Project features contribute Home Manager directory entries with a `shell`
package. Home Manager retains shell outputs through `home.extraDependencies`.
Shells continue to use unstable packages on stable hosts.

Generated `.envrc` files include a stripped derivation fingerprint, load an
ancestor environment, load the host-specific Home Manager shell attribute and
then extend PATH. The host-specific installable regenerates derivation metadata
without retaining `.drv` files in the home closure.

`just refresh-direnvs` refreshes the selected host's caches outside activation.
It detects nix-direnv fallback and reports refresh failures. After a successful
switch and refresh, the update recipe can retire legacy separate shell roots.
Standalone or failed refreshes preserve those roots. The configured checkout
must exist and contain the configuration used for shell loading.

### Installers

Installer payloads target the host's system. ISO assembly uses the build system,
and PXE apps can run on a different system. The installer adapter keeps these
dimensions explicit. Public aliases and publication policy do not depend on
native host-output collection.

## Packages and updates

Every `pkgs/<name>/package.nix` becomes an overlay package and a public package
when available on that platform. Optional `args.nix` files supply explicit
inputs unavailable through ordinary package arguments.

`passthru.tests` exports checks as `<package>-<test>`. `passthru.slowTests`
exports `legacyPackages.<system>.slowChecks`. The router filters availability
and rejects flattened-name collisions. `local-packages` contains discovered
local packages, not every package exported by a feature.

The updater component derives apps and version metadata from package updater
contracts and locked input policy. Dependency updates exercise package tests and
explicitly included shared feature checks, even without a selecting host.

## Validation and public interfaces

`just check` runs the evaluation gate with import from derivation disabled,
evaluates all supported systems and builds native checks. Cupboard schedules
checks according to platform, required system features and `ci.runOnce` policy.
Host-evaluation checks remain private and lazy during public planning.

The public API includes configuration outputs, package/app/check outputs,
formatter, deployment, Cupboard targets, updater metadata and rendered Nix
configuration. `hosts` contains only system strings and resolved feature names;
`username` supports repository commands. Rich host records, feature modules,
inventory and the cache-setting module remain internal.
