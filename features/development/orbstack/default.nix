{
  flake.features.development.provides.orbstack = {
    homeManager = ./home-manager.nix;
    darwin = ./darwin.nix;
  };
}
