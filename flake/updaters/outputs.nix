# Surface each package's update script as `apps.<system>.update-<name>`, so the
# updaters are discoverable with `nix flake show` and runnable with
# `nix run .#update-<name>`. `update-all` runs the lot in sequence.
#
# Package updaters come from each derivation's `passthru.updateScript`
# (attached via `pkgs/build-support/updaters.nix`). Flake inputs get an updater
# here that either advances the release tag or refreshes the branch revision.
#
# `flake.updaterNames` lists the updater names for the package-update workflow
# to iterate, the same way `flake.cupboardOutputs` feeds cupboard.
# `flake.updaterVersions` maps each of those names to its current version, which
# the workflow lists in the pull request.
{
  packages,
  lib,
}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  packageNames = discovery.discoverPackages ../../pkgs;

  # Flake inputs pinned to an immutable release tag in a `github:` URL, each
  # bumped by a generated updater named `update-<input>`.
  releaseInputs = [
    "catppuccin-palette"
    "codex-plugin-cc"
    "gh-stack-skill"
  ];

  branchInputs = ["hermes-agent"];
  flakeInputs = releaseInputs ++ branchInputs;

  # A flake input exposes only the revision that it is locked to. The owner,
  # repository and ref come from the `original` reference, which
  # `nix flake update` records in flake.lock.
  lockNodes = (lib.importJSON ../../flake.lock).nodes;
  lockedReference = input: (lockNodes.${lockNodes.root.inputs.${input} or ""} or {}).original or {};

  flakeInputsHaveGithubRefs =
    lib.all (
      input:
        lib.assertMsg
        ((lockedReference input).type or null == "github" && lockedReference input ? ref)
        "flake/updaters/outputs.nix: ${input} must use a github: URL with an explicit ref"
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
        (lib.attrValues packages)
    )
    packageNames;

  updaterNames = assert flakeInputsHaveGithubRefs;
    packageUpdaterNames ++ flakeInputs;

  packageVersion = name:
    (lib.findFirst (packages: packages ? ${name}) {} (lib.attrValues packages)).${name}.version or "";

  updaterVersions =
    lib.genAttrs packageUpdaterNames packageVersion
    // lib.genAttrs releaseInputs (input: (lockedReference input).ref)
    // lib.genAttrs branchInputs (input: lockNodes.${lockNodes.root.inputs.${input}}.locked.rev);
in {
  apps = {pkgs, ...}: let
    packageUpdaters =
      lib.genAttrs
      (lib.filter (hasUpdateScript pkgs) packageNames)
      (name: pkgs.${name}.updateScript);

    flakeInputUpdaters =
      lib.genAttrs releaseInputs (input:
        pkgs.updaters.mkFlakeInputUpdater {
          inherit input;
          inherit (lockedReference input) owner repo ref;
        })
      // lib.genAttrs branchInputs (input:
        pkgs.updaters.mkFlakeBranchUpdater {inherit input;});

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
  in
    {
      apps =
        lib.mapAttrs' toApp updaters
        // {
          update-all = {
            type = "app";
            program = lib.getExe updateAll;
            meta.description = "Run every package and flake-input updater in sequence";
          };
        };
    }.apps;

  inherit updaterNames updaterVersions;
}
