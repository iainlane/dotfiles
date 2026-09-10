{config, ...}: {
  flake.features.hermes.provides.webhook = {
    includes = [config.flake.features.hermes];
    systemManager.imports = [./options.nix ./system-manager.nix];
  };
}
