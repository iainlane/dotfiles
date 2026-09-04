{
  flake.features.desktop.provides.cursor = {
    kernel.linux.homeManager = ./home-manager-linux.nix;
    os.darwin.homeManager = ./home-manager-darwin.nix;
  };
}
