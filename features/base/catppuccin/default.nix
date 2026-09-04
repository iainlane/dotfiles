{
  flake.features.base.provides.catppuccin = {
    homeManager = ./home-manager.nix;
    nixos = ./nixos.nix;
  };
}
