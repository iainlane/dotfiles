{
  flake.features.development.provides.debuginfod = {
    nixos = ./nixos.nix;
    os = {
      "generic-linux".homeManager = ./home-manager-linux.nix;
      nixos.homeManager = ./home-manager-linux.nix;
    };
  };
}
