{
  config,
  inputs,
  lib,
  ...
}: let
  outputs = import ./outputs.nix {
    inherit inputs lib;
    inherit (config.flake) packages;
  };
  checks = import ./checks.nix {
    inherit lib inputs;
    inherit (config.flake) updaterNames updaterVersions;
  };
in {
  options.flake = {
    updaterNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
    };
    updaterVersions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
    };
    packageVersions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
    };
  };
  config = {
    perSystem = {
      pkgs,
      pkgs-stable,
      system,
      ...
    }: let
      systemOutputs = outputs.forSystem {inherit pkgs pkgs-stable system;};
    in {
      inherit (systemOutputs) apps legacyPackages;
      checks = checks {
        inherit pkgs pkgs-stable;
        inherit (systemOutputs) apps;
        inherit (systemOutputs.legacyPackages) updaterScripts;
      };
    };
    flake = {inherit (outputs) packageVersions updaterNames updaterVersions;};
  };
}
