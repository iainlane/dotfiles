{config, ...}: {
  dotfiles.features.hermes.identity = {
    includes = [config.dotfiles.features.hermes];
    systemManager.imports = [./options.nix ./system-manager.nix];
  };
}
