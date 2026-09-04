{
  flake.features.git = {
    homeManager = ./home-manager.nix;
    os = {
      darwin.homeManager = ./credential-darwin.nix;
      "generic-linux".homeManager = [./credential-linux.nix ./gitsign.nix];
      nixos.homeManager = [./credential-linux.nix ./gitsign.nix];
    };
  };
}
