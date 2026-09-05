{
  flake.features.desktop.provides.voxtype = {
    kernel.linux.homeManager = ./home-manager-linux.nix;
    os.darwin.homeManager = ./home-manager-darwin.nix;
  };
}
