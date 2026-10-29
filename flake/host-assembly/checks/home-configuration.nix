{
  inputs,
  lib,
}: {pkgs, ...}: let
  home = import ../../../lib/home.nix {
    inherit inputs lib;
    featureResolver = {};
  };
  evaluate = module:
    home.mkHomeConfiguration {
      homeManager = inputs.home-manager;
      pkgs = pkgs // {fixtureMarker = "provided";};
      modules = [
        ({pkgs, ...}: {
          home = {
            username = "fixture";
            homeDirectory = "/home/fixture";
            stateVersion = "26.05";
            sessionVariables.FIXTURE_PACKAGES = pkgs.fixtureMarker or "imported";
          };
        })
        module
      ];
    };
  configuration = evaluate {};
  otherSystem =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    then "aarch64-linux"
    else "x86_64-linux";
  ignored = lib.mapAttrs (_: evaluate) {
    config.nixpkgs.config.allowBroken = true;
    overlays.nixpkgs.overlays = [(_: _: {})];
    system.nixpkgs.system = otherSystem;
  };
  evaluates = configuration: (builtins.tryEval configuration.activationPackage.drvPath).success;
  actual = {
    packages = configuration.config.home.sessionVariables.FIXTURE_PACKAGES;
    shared = evaluates configuration;
    ignored = lib.mapAttrs (_: evaluates) ignored;
  };
  expected = {
    packages = "provided";
    shared = true;
    ignored = {
      config = false;
      overlays = false;
      system = false;
    };
  };
in {
  home-configuration-packages = assert lib.assertMsg (actual == expected)
  "Standalone Home Manager modules received ${builtins.toJSON actual}, expected ${builtins.toJSON expected}.";
    pkgs.runCommandLocal "home-configuration-packages" {} ''touch "$out"'';
}
