{featureResolver, ...}: {
  flake.features.work.provides.falcon = {
    includes = [(featureResolver.when featureResolver.isNixos [{checks = ./checks.nix;}])];
    nixos = [./service.nix ./nixos.nix];
  };
}
