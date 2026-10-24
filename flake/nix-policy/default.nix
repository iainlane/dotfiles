{
  config,
  lib,
  featureResolver,
  hostResults,
  ...
}: let
  hostCaches = import ./checks/host-caches.nix {
    inherit lib hostResults featureResolver;
    inherit (config.dotfiles) hosts;
  };
  evaluation = import ./checks/evaluation.nix {inherit lib;};
in {
  imports = [./settings.nix];
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    checks = lib.mkMerge [
      (hostCaches {inherit pkgs system;})
      (evaluation {inherit pkgs;})
    ];
  };
}
