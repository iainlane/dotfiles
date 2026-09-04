{
  flake.features.voxtype = {
    homeManager = ./home-manager.nix;
    os = {
      darwin.homeManager = ./darwin.nix;
      linux.homeManager = ./linux.nix;
      nixos.homeManager = ./linux.nix;
    };
  };
}
