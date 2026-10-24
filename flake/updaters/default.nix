{
  config,
  lib,
  ...
}: let
  outputs = import ./outputs.nix {
    inherit lib;
    inherit (config.flake) packages;
  };
  checks = import ./checks.nix {
    inherit lib;
    inherit (config.flake) packages updaterNames updaterVersions;
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
  };
  config = {
    perSystem = {pkgs, ...}: {
      apps = outputs.apps {inherit pkgs;};
      checks = checks {inherit pkgs;};
    };
    flake = {inherit (outputs) updaterNames updaterVersions;};
  };
}
