{featureResolver, ...}: {
  flake.features.development.provides.debuginfod = {
    includes = [
      (featureResolver.when featureResolver.isLinux [{homeManager = ./home-manager-linux.nix;}])
    ];
    nixos = ./nixos.nix;
  };
}
