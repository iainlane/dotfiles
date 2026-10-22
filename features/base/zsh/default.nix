{featureResolver, ...}: {
  flake.features.base.provides.zsh = {
    checks = [./zsh-check.nix];
    includes = [
      (featureResolver.when featureResolver.isLinux [{homeManager = ./home-manager-linux.nix;}])
      (featureResolver.when featureResolver.isDarwin [{homeManager = ./home-manager-darwin.nix;}])
      (featureResolver.when featureResolver.isGenericLinux [{homeManager = ./home-manager-generic-linux.nix;}])
    ];
    homeManager = ./home-manager.nix;
    darwin = ./system.nix;
    nixos = ./system.nix;
  };
}
