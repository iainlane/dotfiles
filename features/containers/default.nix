{
  config,
  lib,
  ...
}: {
  dotfiles.flakeSystem.includes = [config.dotfiles.features.containers];
  dotfiles.features.containers = {
    checks = [(import ./checks/image-absent.nix {}) (import ./checks/quadlet.nix {inherit lib;})];
    systemManager = ./system-manager.nix;
    nixos = ./nixos.nix;
  };
}
