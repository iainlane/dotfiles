# Surface each package's update script as `apps.<system>.update-<name>`, so the
# updaters are discoverable with `nix flake show` and runnable with
# `nix run .#update-<name>`. `update-all` runs the lot in sequence.
#
# Package updaters come from each derivation's `passthru.updateScript`
# (attached via `pkgs/build-support/updaters.nix`). Flake inputs pinned to a
# release tag, which `nix flake update` cannot move, get an updater here.
#
# `flake.updaterNames` lists the updater names for the package-update workflow
# to iterate, the same way `flake.cupboardOutputs` feeds cupboard.
{
  config,
  inputs,
  lib,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
  packageNames = helpers.discoverPackages ../../pkgs;

  # Flake inputs pinned to an immutable release tag, each bumped by a generated
  # updater named `update-<input>`.
  flakeInputs = {
    gh-stack-skill.repo = "github/gh-stack";
    hermes-agent.repo = "NousResearch/hermes-agent";
  };

  hasUpdateScript = packages: name: (packages.${name} or null) ? updateScript;

  # `flake.packages` omits packages that are not available on a system, so a
  # package gets an updater when it defines an update script in at least one
  # system's package set.
  updaterNames =
    lib.filter (
      name:
        lib.any
        (packages: hasUpdateScript packages name)
        (lib.attrValues config.flake.packages)
    )
    packageNames
    ++ lib.attrNames flakeInputs;
in {
  perSystem = {pkgs, ...}: let
    packageUpdaters =
      lib.genAttrs
      (lib.filter (hasUpdateScript pkgs) packageNames)
      (name: pkgs.${name}.updateScript);

    flakeInputUpdaters =
      lib.mapAttrs
      (input: cfg:
        pkgs.updaters.mkFlakeInputUpdater {
          inherit input;
          inherit (cfg) repo;
        })
      flakeInputs;

    updaters = packageUpdaters // flakeInputUpdaters;

    updateAll = pkgs.writeShellApplication {
      name = "update-all";
      runtimeInputs = lib.attrValues updaters;
      text = lib.concatMapStringsSep "\n" lib.getExe (lib.attrValues updaters);
    };

    toApp = name: updater: {
      name = "update-${name}";
      value = {
        type = "app";
        program = lib.getExe updater;
        meta.description = "Update ${name} to its latest upstream version";
      };
    };
  in {
    apps =
      lib.mapAttrs' toApp updaters
      // {
        update-all = {
          type = "app";
          program = lib.getExe updateAll;
          meta.description = "Run every package and flake-input updater in sequence";
        };
      };
  };

  flake.updaterNames = updaterNames;
}
