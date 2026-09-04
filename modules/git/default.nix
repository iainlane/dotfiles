{
  flake.features.git = {
    homeManager = ./home-manager.nix;
    os = {
      darwin.homeManager = ./credential-darwin.nix;
      linux.homeManager = [./credential-linux.nix ./gitsign.nix];
      nixos.homeManager = [./credential-linux.nix ./gitsign.nix];
    };
  };
}
