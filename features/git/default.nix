{
  flake.features.git = {
    homeManager = ./home-manager.nix;
    os = {
      darwin.homeManager = ./home-manager-darwin.nix;
      "generic-linux".homeManager = [./home-manager-linux.nix ./gitsign.nix];
      nixos.homeManager = [./home-manager-linux.nix ./gitsign.nix];
    };
  };
}
