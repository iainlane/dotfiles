{
  flake.features.desktop.provides.voxtype = {
    homeManager = ./home-manager.nix;
    os = {
      darwin.homeManager = ./home-manager-darwin.nix;
      "generic-linux".homeManager = ./home-manager-linux.nix;
      nixos.homeManager = ./home-manager-linux.nix;
    };
  };
}
