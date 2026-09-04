{
  flake.features.base.provides.cli-tools = {
    homeManager = ./home-manager.nix;
    kernel.linux.homeManager = ./home-manager-linux.nix;
  };
}
