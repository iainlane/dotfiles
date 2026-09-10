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
  inputs,
  config,
  lib,
  ...
}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  packageNames = discovery.discoverPackages ../../pkgs;

  # Flake inputs pinned to an immutable release tag, each bumped by a generated
  # updater named `update-<input>`.
  flakeInputs = {
    catppuccin-palette.repo = "catppuccin/palette";
    gh-stack-skill.repo = "github/gh-stack";
    hermes-agent.repo = "NousResearch/hermes-agent";
  };

  # Every key must match an input in `flake.nix`. An updater generated for a
  # key that matches none would leave `flake.nix` unchanged and report
  # success.
  flakeInputsExist =
    lib.assertMsg
    (lib.all (name: inputs ? ${name}) (lib.attrNames flakeInputs))
    "flake/parts/updaters.nix: flakeInputs names an input flake.nix does not have";

  hasUpdateScript = packages: name: (packages.${name}.updateScript or null) != null;

  # `flake.packages` omits packages that are not available on a system, so a
  # package gets an updater when it defines an update script in at least one
  # system's package set.
  updaterNames = assert flakeInputsExist;
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

    # Run every updater so one upstream failure does not stop the others.
    # Report the failures together and exit nonzero.
    updateAll = pkgs.writeShellApplication {
      name = "update-all";
      text = ''
        failed=()

        ${
          lib.concatStringsSep "\n"
          (lib.mapAttrsToList
            (name: updater: ''${lib.getExe updater} || failed+=("update-${name}")'')
            updaters)
        }

        if ((''${#failed[@]} > 0)); then
          printf 'These updaters failed: %s\n' "''${failed[*]}" >&2
          exit 1
        fi
      '';
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
