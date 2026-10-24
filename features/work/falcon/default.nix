{featureResolver, ...}: {
  dotfiles.features.work.falcon = {
    includes = [(featureResolver.when featureResolver.isNixos [{checks = ./checks.nix;}])];
    nixos = [./service.nix ./nixos.nix];
  };
}
