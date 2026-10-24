{featureResolver, ...}: {
  dotfiles.features.desktop.fonts = {
    includes = [
      (featureResolver.when featureResolver.isDarwin [{homeManager = ./home-manager-packages.nix;}])
      (featureResolver.when featureResolver.isGenericLinux [{homeManager = ./home-manager-packages.nix;}])
    ];
    homeManager = ./home-manager.nix;
    nixos = ./nixos.nix;

    # `nixos.nix` puts the same list in `fonts.packages`, so NixOS hosts must
    # not install these fonts in the user profile as well.
  };
}
