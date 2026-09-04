{
  flake.features.containers = {
    systemManager = ./system-manager.nix;
    nixos = ./nixos.nix;
  };
}
