{
  flake.features.zsh = {
    homeManager = ./home-manager.nix;
    os = {
      darwin.homeManager = ./darwin.nix;
      "generic-linux".homeManager = ./linux.nix;
      nixos.homeManager = ./linux.nix;
    };
  };
}
