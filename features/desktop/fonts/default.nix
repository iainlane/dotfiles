{
  flake.features.desktop.provides.fonts = {
    homeManager = ./home-manager.nix;
    nixos = ./nixos.nix;
  };
}
