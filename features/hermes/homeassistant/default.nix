{featureResolver, ...}: {
  flake.features.hermes.provides.homeassistant = {
    includes = [(featureResolver.when featureResolver.isGenericLinux [{checks = ./checks.nix;}])];
    systemManager.imports = [./system-manager.nix];
  };
}
