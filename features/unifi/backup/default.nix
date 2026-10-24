{config, ...}: {
  dotfiles = {
    flakeSystem.includes = [config.dotfiles.features.unifi.backup];
    features.unifi.backup = {
      checks = [./unifi-backup-check.nix];
      systemManager.imports = [
        ./options.nix
        ./system-manager.nix
      ];
    };
  };
}
