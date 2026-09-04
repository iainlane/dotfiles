{
  flake.features.base.provides.gh.homeManager = [
    ./home-manager.nix
    ./gh-dash.nix
  ];
}
