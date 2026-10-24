{config, ...}: {
  dotfiles.features.hermes.webhook = {
    includes = [config.dotfiles.features.hermes];
    systemManager.imports = [./options.nix ./system-manager.nix];
  };
}
