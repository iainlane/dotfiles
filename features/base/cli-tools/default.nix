{featureResolver, ...}: {
  flake.features.base.provides.cli-tools = {
    includes = [
      (featureResolver.when featureResolver.isGenericLinux [{homeManager = ./home-manager-generic-linux.nix;}])
    ];
    homeManager = ./home-manager.nix;
  };
}
