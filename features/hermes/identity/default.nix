{config, ...}: {
  flake.features.hermes.provides.identity = {
    includes = [config.flake.features.hermes];
    systemManager.imports = [./options.nix ./system-manager.nix];
  };
}
