{
  flake.features.git = {
    homeManager = ./home-manager.nix;
    kernel.linux.homeManager = [./home-manager-linux.nix ./gitsign.nix];
    os.darwin.homeManager = ./home-manager-darwin.nix;
  };
}
