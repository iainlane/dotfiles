{config, ...}: {
  dotfiles.features.hermes.inbox = {
    includes = [
      config.dotfiles.features.hermes
      config.dotfiles.features.hermes.webhook
      config.dotfiles.features.hermes.matrix
    ];
    systemManager.imports = [./options.nix ./system-manager.nix];
  };
}
