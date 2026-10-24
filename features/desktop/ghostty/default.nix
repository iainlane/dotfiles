{featureResolver, ...}: {
  dotfiles.features.desktop.ghostty = {
    includes = [
      (featureResolver.when featureResolver.isLinux [{homeManager = ./home-manager-linux.nix;}])
      (featureResolver.when featureResolver.isDarwin [{homeManager = ./home-manager-darwin.nix;}])
    ];
    homeManager = ./home-manager.nix;
  };
}
