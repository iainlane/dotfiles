{
  flake.modules.catppuccin = {
    homeManagerModules = [./home-manager.nix];
    nixosModules = [./nixos.nix];
  };
}
