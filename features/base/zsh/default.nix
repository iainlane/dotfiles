{
  flake.features.base.provides.zsh = {
    homeManager = ./home-manager.nix;
    kernel.linux.homeManager = ./home-manager-linux.nix;
    os = {
      darwin.homeManager = ./home-manager-darwin.nix;
      generic-linux.homeManager = ./home-manager-generic-linux.nix;
    };
  };
}
