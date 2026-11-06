{featureResolver, ...}: {
  dotfiles.features.desktop.usbguard = {
    includes = [(featureResolver.when featureResolver.isNixos [{checks = ./checks.nix;}])];
    nixos = [
      ./options.nix
      ./nixos.nix
    ];
  };
}
