{config, ...}: {
  flake.features.hermes.provides.inbox = {
    includes = [
      config.flake.features.hermes
      config.flake.features.hermes.provides.webhook
      config.flake.features.hermes.provides.matrix
    ];
    systemManager.imports = [./options.nix ./system-manager.nix];
  };
}
