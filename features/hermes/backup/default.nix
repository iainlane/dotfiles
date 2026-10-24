{config, ...}: {
  dotfiles = {
    flakeSystem.includes = [config.dotfiles.features.hermes.backup];
    features.hermes.backup = {
      checks = [./hermes-inbox-backup-check.nix];
      systemManager.imports = [
        ./options.nix
        ./system-manager.nix
      ];
    };
  };
}
