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
# `flake.updaterVersions` maps each of those names to its current version, which
# the workflow lists in the pull request.
{
  config,
  lib,
  ...
}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  packageNames = discovery.discoverPackages ../../pkgs;

  # Flake inputs pinned to an immutable release tag in a `github:` URL, each
  # bumped by a generated updater named `update-<input>`.
  flakeInputs = [
    "catppuccin-palette"
    "codex-plugin-cc"
    "gh-stack-skill"
    "hermes-agent"
  ];

  # A flake input exposes only the revision that it is locked to. The owner,
  # repository and tag come from the `original` reference, which
  # `nix flake update` records in flake.lock.
  lockNodes = (lib.importJSON ../../flake.lock).nodes;
  lockedReference = input: (lockNodes.${lockNodes.root.inputs.${input} or ""} or {}).original or {};

  flakeInputsArePinned =
    lib.all (
      input:
        lib.assertMsg
        ((lockedReference input).type or null == "github" && lockedReference input ? ref)
        "flake/parts/updaters.nix: ${input} is not a flake input pinned to a tag in a github: URL"
    )
    flakeInputs;

  hasUpdateScript = packages: name: (packages.${name}.updateScript or null) != null;

  # `flake.packages` omits packages that are not available on a system, so a
  # package gets an updater when it defines an update script in at least one
  # system's package set.
  packageUpdaterNames =
    lib.filter (
      name:
        lib.any
        (packages: hasUpdateScript packages name)
        (lib.attrValues config.flake.packages)
    )
    packageNames;

  updaterNames = assert flakeInputsArePinned;
    packageUpdaterNames ++ flakeInputs;

  packageVersion = name:
    (lib.findFirst (packages: packages ? ${name}) {} (lib.attrValues config.flake.packages)).${name}.version or "";

  updaterVersions =
    lib.genAttrs packageUpdaterNames packageVersion
    // lib.genAttrs flakeInputs (input: (lockedReference input).ref);
in {
  perSystem = {pkgs, ...}: let
    packageUpdaters =
      lib.genAttrs
      (lib.filter (hasUpdateScript pkgs) packageNames)
      (name: pkgs.${name}.updateScript);

    flakeInputUpdaters = lib.genAttrs flakeInputs (input:
      pkgs.updaters.mkFlakeInputUpdater {
        inherit input;
        inherit (lockedReference input) owner repo ref;
      });

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
  flake.updaterVersions = updaterVersions;
}
