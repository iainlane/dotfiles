{
  flake.features.base.provides.cli-tools = {
    homeManager = ./home-manager.nix;
    os.generic-linux.homeManager = ./home-manager-generic-linux.nix;
  };
}
