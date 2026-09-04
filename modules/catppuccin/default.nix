{
  flake.features.catppuccin = {
    homeManager = ./home-manager.nix;
    nixos = ./nixos.nix;
  };
}
