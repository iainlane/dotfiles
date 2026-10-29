{
  inputs,
  lib,
}: {pkgs, ...}: let
  evaluate = module:
    inputs.system-manager.lib.makeSystemConfig {
      modules = [
        ../../../os/generic-linux/nixpkgs.nix
        {nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;}
        module
      ];
      specialArgs.pkgs = pkgs // {fixtureMarker = "provided";};
    };
  shared = evaluate ({pkgs, ...}: {
    environment.etc.fixture.text = pkgs.fixtureMarker or "imported";
  });
  otherSystem =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    then "aarch64-linux"
    else "x86_64-linux";
  ignored = lib.mapAttrs (_: evaluate) {
    overlays.nixpkgs.overlays = [(_: _: {})];
    config.nixpkgs.config.allowBroken = true;
    buildPlatform.nixpkgs.buildPlatform = otherSystem;
    hostPlatform.nixpkgs.hostPlatform = lib.mkForce otherSystem;
  };
  evaluates = configuration: (builtins.tryEval configuration.options).success;
  actual = {
    modules = shared.config.environment.etc.fixture.text;
    toplevel = shared.config.nixpkgs.pkgs.fixtureMarker or "imported";
    shared = evaluates shared;
    ignored = lib.mapAttrs (_: evaluates) ignored;
  };
  expected = {
    modules = "provided";
    toplevel = "provided";
    shared = true;
    ignored = {
      overlays = false;
      config = false;
      buildPlatform = false;
      hostPlatform = false;
    };
  };
in
  lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    system-manager-packages = assert lib.assertMsg (actual == expected)
    "system-manager evaluated ${builtins.toJSON actual}, expected ${builtins.toJSON expected}.";
      pkgs.runCommandLocal "system-manager-packages" {} ''touch "$out"'';
  }
