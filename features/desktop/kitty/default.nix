{
  flake.features.desktop.provides.kitty = {
    homeManager = ./home-manager.nix;
    kernel.linux.homeManager = ./home-manager-linux.nix;
    os.darwin.homeManager = ./home-manager-darwin.nix;
  };
}
