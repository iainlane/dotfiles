{
  inputs,
  packages,
  lib,
}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  packageNames = discovery.discoverPackages ../../pkgs;
  releaseInputs = ["catppuccin-palette" "codex-plugin-cc" "gh-stack-skill" "mcp-nixos"];
  branchInputs = ["hermes-agent"];
  flakeInputs = releaseInputs ++ branchInputs;
  lockNodes = (lib.importJSON ../../flake.lock).nodes;
  reference = input: lockNodes.${lockNodes.root.inputs.${input}}.original;
  hasUpdater = set: name: set ? ${name} && set.${name} ? maintenance && (set.${name}.updateScript or null) != null;
  packageUpdaterNames = lib.filter (name: lib.any (set: hasUpdater set name) (lib.attrValues packages)) packageNames;
  packageVersion = name: (lib.findFirst (set: set ? ${name}) {} (lib.attrValues packages)).${name}.version or "";
in {
  updaterNames = packageUpdaterNames ++ flakeInputs;
  packageVersions = lib.genAttrs packageNames packageVersion;
  updaterVersions =
    lib.genAttrs packageUpdaterNames packageVersion
    // lib.genAttrs releaseInputs (input: (reference input).ref)
    // lib.genAttrs branchInputs (input: lockNodes.${lockNodes.root.inputs.${input}}.locked.rev);

  forSystem = {
    pkgs,
    pkgs-stable,
    system,
  }: let
    packageScripts = lib.genAttrs (lib.filter (hasUpdater pkgs) packageNames) (name: pkgs.${name}.updateScript);
    inputScripts =
      lib.genAttrs releaseInputs (input:
        pkgs.updaters.mkFlakeInputUpdater {
          inherit input;
          inherit (reference input) owner repo ref;
        })
      // lib.genAttrs branchInputs (input: pkgs.updaters.mkFlakeBranchUpdater {inherit input;});
    scripts = packageScripts // inputScripts;
    metadata =
      lib.mapAttrs (name: script: let
        policy = pkgs.${name}.maintenance or {};
        isInput = builtins.elem name flakeInputs;
      in {
        refresh = !isInput && (policy.refresh or false);
        paths =
          if isInput
          then ["flake.nix" "flake.lock"]
          else ["pkgs/${name}"];
        program = script.meta.mainProgram or script.name;
        input =
          if isInput
          then name
          else null;
      })
      scripts;
    available = packages.${system} or {};
    nodes = pkgs.writeText "update-plan-nodes.json" (builtins.toJSON (
      map (name: {
        inherit name;
        path =
          if available ? ${name}
          then builtins.unsafeDiscardStringContext available.${name}.drvPath
          else null;
        updater = scripts ? ${name};
        refresh = metadata.${name}.refresh or false;
        dependencies = available.${name}.maintenance.dependencies or null;
      })
      packageNames
      ++ map (name: {
        inherit name;
        path = builtins.unsafeDiscardStringContext inputs.${name}.outPath;
        updater = true;
      })
      flakeInputs
    ));
    run = command:
      pkgs.writeShellApplication {
        name = "update-${command}";
        runtimeInputs = [pkgs.update-runner];
        text = ''exec update-runner ${command} "$@"'';
      };
    app = script: {
      type = "app";
      program = lib.getExe script;
    };
  in {
    apps =
      lib.mapAttrs' (name: _:
        lib.nameValuePair "update-${name}" (app (pkgs.writeShellApplication {
          name = "update-${name}";
          runtimeInputs = [pkgs.update-runner];
          text = ''exec update-runner package ${lib.escapeShellArg name} "$@"'';
        })))
      scripts
      // {
        update-all = app (run "packages");
        update-flake = app (run "inputs");
        update-plan = app (pkgs.writeShellApplication {
          name = "update-plan";
          runtimeInputs = [pkgs.update-plan];
          text = ''exec update-plan --nodes ${nodes} "$@"'';
        });
      };
    legacyPackages = {
      updaterScripts = scripts;
      updaterMetadata = metadata;
      maintenanceTargets.caddy = lib.mapAttrs (_: set: set.caddy.src.overrideAttrs {outputHash = lib.fakeHash;}) {
        stable = pkgs-stable;
        unstable = pkgs;
      };
    };
  };
}
