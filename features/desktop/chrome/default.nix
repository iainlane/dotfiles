{
  flake.features.desktop.provides.chrome = {
    darwin = ./darwin.nix;

    kernel.linux.homeManager = ./home-manager-linux.nix;
    os.darwin.homeManager = ./home-manager-darwin.nix;
  };
}
