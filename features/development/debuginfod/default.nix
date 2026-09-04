{
  flake.features.development.provides.debuginfod = {
    nixos = ./nixos.nix;
    kernel.linux.homeManager = ./home-manager-linux.nix;
  };
}
