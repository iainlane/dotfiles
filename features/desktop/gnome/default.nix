{
  flake.features.desktop.provides.gnome = {
    nixos = ./nixos.nix;
    homeManager = ./home-manager.nix;
  };
}
