# Architecture

This repo is a [flake-parts] flake that produces NixOS, nix-darwin,
[system-manager], and [Home Manager] configurations for several machines from
one shared set of building blocks.

The data flows in one direction:

```text
host  →  profiles  →  features  →  OS adapter  →  flake outputs
```

Each stage is described below.

[flake-parts]: https://flake.parts
[system-manager]: https://github.com/numtide/system-manager
[Home Manager]: https://nix-community.github.io/home-manager/

## Hosts

A host is one machine. Host records live in `hosts/*.nix` (or
`hosts/<name>/default.nix` when a host needs extra files such as `hardware.nix`
and `disks.nix`). They are discovered automatically — there is no hand-written
list to keep in sync.

A host declares its OS and architecture, the profiles it wants, and any per-host
overrides:

```nix
{
  hostname = "florence.example.com";
  os = "nixos"; # or "darwin" / "linux" (system-manager)
  arch = "x86_64";
  profiles = ["base" "desktop" "development"];

  # Optional per-host tweak.
  homeModule = {...}: {
    programs.git.settings.user.email = "me@example.com";
  };
}
```

The `flake.hosts` option (in `flake/parts/hosts.nix`) types and normalises these
records and computes derived fields such as `system` and `homeDirectory`.

## Profiles

A profile is a composable bundle of behaviour: `base`, `desktop`, `development`,
`work`, and so on. Profiles live in `profiles/*/default.nix` and are discovered
automatically. A host selects profiles by name; a profile can also carry
per-host options when a host selects it as `{ adsb = { ... }; }` instead of the
bare string `"adsb"`.

Profiles compose **features** and may contribute their own inline modules:

```nix
flake.profiles.base = {
  features = [
    "catppuccin"
    "git"
    "neovim"
    "zsh"
    # ...
  ];

  # Inline configuration that is specific to this profile.
  homeManagerModule = {pkgs, ...}: {
    # ...
  };
};
```

Profiles can also scope both features and inline modules to a specific OS via
`flake.profiles.<name>.os.<os>`, e.g. `base.os.nixos.features = ["borgmatic"]`.

A profile can declare that it needs another profile present with `requires`. The
requirement is validated while the host set is evaluated (in
`flake/parts/hosts.nix`, via `validateProfileRequirements`), so a missing or
self-referential requirement fails before any build; the
[contract checks](#contract-checks) also exercise this logic directly.

## Features and modules

A feature is a self-contained unit of configuration for one program or a small
group of them (`git`, `zsh`, `neovim`, `ghostty`, …). Feature modules live in
`modules/*/default.nix` and register themselves under `flake.modules.<name>`:

```nix
# modules/git/default.nix
{
  flake.modules.git = {
    homeManagerModules = [./home-manager.nix];
    os = {
      darwin.homeManagerModules = [./credential-darwin.nix];
      linux.homeManagerModules = [./credential-linux.nix ./gitsign.nix];
      nixos.homeManagerModules = [./credential-linux.nix ./gitsign.nix];
    };
  };
}
```

Each feature exposes module lists per target — `homeManagerModules`,
`systemManagerModules`, `nixosModules` — plus OS-specific variants under `os`.

Profiles reference features **by name**. The name is resolved against
`flake.modules` during module assembly (`lib/profiles.nix`, `mkModules`), so a
typo fails with a clear "unknown feature" error naming the profile, and the
profile layer stays declarative rather than carrying opaque module values.

## OS adapters

For a given host, the selected profiles resolve to a flat list of modules for
each target. The OS adapters in `os/<os>/default.nix` take that list and hand it
to the right system builder:

- `os/nixos` → `nixpkgs.lib.nixosSystem` (also embeds Home Manager, and grafts
  the unstable `lib.hm` onto stable hosts so unstable HM modules evaluate),
- `os/darwin` → `nix-darwin.lib.darwinSystem` (embeds Home Manager),
- `os/linux` → `system-manager.lib.makeSystemConfig` (Home Manager is deployed
  standalone rather than embedded).

Shared plumbing — profile/module resolution, Home Manager assembly, sops
fragments — lives in `lib/` so the three adapters only own the parts that
genuinely differ between the system builders.

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

| File                | Responsibility                                       |
| ------------------- | ---------------------------------------------------- |
| `lib/discovery.nix` | filesystem discovery (hosts/profiles/modules/pkgs)   |
| `lib/hosts.nix`     | host record loading                                  |
| `lib/profiles.nix`  | profile normalisation, validation, module resolution |
| `lib/home.nix`      | Home Manager module + `specialArgs` assembly         |
| `lib/sops.nix`      | sops-nix module fragments                            |
| `lib/projects.nix`  | project shell / direnv generation                    |

## Contract checks

Formatting and linting are covered by the `treefmt`/`statix`/… checks in
`flake/parts/checks.nix`. The `profile-contracts` check in
`flake/parts/checks-contracts.nix` guards the _architecture_ instead: it
evaluates the resolution contract during `nix flake check` and fails if

- name resolution or composition order regresses (base + OS feature exports,
  OS-scoped profile features, and Home Manager / system-manager / NixOS
  targets),
- a feature name is unknown or a profile is declared twice on one host,
- a profile requirement is missing or self-referential,
- a profile references a feature that is not in `flake.modules`, or an `os.<os>`
  scope key is not a known operating system.

The assertions are pure evaluation, so they run inside a pure flake check.

The `adapter-evals` check (`flake/parts/checks-adapters.nix`) complements the
fixture-based contracts by pointing at the real outputs: it forces the toplevel
derivation of every host configuration (NixOS, nix-darwin, system-manager, and
standalone Home Manager), so a configuration that no longer evaluates fails
`nix flake check` without the host configurations being built. Evaluating the
configurations reads the private secrets input, so this check needs access to
it.
