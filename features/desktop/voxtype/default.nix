{featureResolver, ...}: {
  flake.features.desktop.provides.voxtype = {
    includes = [
      (featureResolver.when featureResolver.isLinux [{homeManager = ./home-manager-linux.nix;}])
      (featureResolver.when featureResolver.isDarwin [{homeManager = ./home-manager-darwin.nix;}])
    ];
  };
}
