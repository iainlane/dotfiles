{
  config,
  lib,
  pkgs,
  ...
}: {
  assertions = [
    {
      assertion =
        config.nixpkgs.overlays
        == []
        && config.nixpkgs.config == {}
        && (lib.systems.elaborate config.nixpkgs.hostPlatform).system == pkgs.stdenv.hostPlatform.system
        && (lib.systems.elaborate config.nixpkgs.buildPlatform).system == pkgs.stdenv.buildPlatform.system;
      message = "system-manager hosts use the shared unstable package set for their own system, so nixpkgs.overlays, nixpkgs.config and a different nixpkgs.hostPlatform or nixpkgs.buildPlatform have no effect. Change flake/local-packages/context.nix instead.";
    }
  ];
}
