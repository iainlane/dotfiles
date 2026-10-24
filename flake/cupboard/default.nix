{
  config,
  inputs,
  lib,
  featureResolver,
  ...
}: {
  imports = [./targets.nix];
  options.flake = let
    targetType = lib.types.submodule {
      options =
        lib.genAttrs ["attr" "rootDrvPath" "rootSuffix" "system" "cohort" "os"] (_: lib.mkOption {type = lib.types.str;})
        // lib.genAttrs ["bestEffort" "remote"] (_: lib.mkOption {type = lib.types.bool;});
    };
  in
    lib.genAttrs ["cupboardOutputs" "cupboardPublicOutputs"] (_:
      lib.mkOption {
        type = lib.types.listOf targetType;
        readOnly = true;
      });
  config.perSystem.imports = [
    (import ./checks/targets.nix {
      inherit lib featureResolver;
      inherit (config.dotfiles) hosts username;
      inherit (config) systems;
      inherit (config.flake) checks;
      slowChecks = config.flake.legacyPackages.${(import ../../lib/ci.nix).validationSystem}.slowChecks;
      targets = config.flake.cupboardOutputs;
    })
    (import ./checks/workflows.nix {
      inherit inputs lib;
      inherit (config) systems;
      nixConfiguration = config.flake.nix;
    })
    ./checks/retry.nix
  ];
}
