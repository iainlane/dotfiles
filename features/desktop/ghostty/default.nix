{
  flake.features.desktop.provides.ghostty = {
    homeManager = ./home-manager.nix;
    kernel.linux.homeManager = ./home-manager-linux.nix;
    os.darwin.homeManager = ./home-manager-darwin.nix;
  };
}
