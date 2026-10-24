{config, ...}: {
  dotfiles = {
    flakeSystem.includes = [config.dotfiles.features.agentsview-server.backup];
    features.agentsview-server.backup = {
      checks = ./checks.nix;
      systemManager.imports = [
        ./options.nix
        ./system-manager.nix
      ];
    };
  };
}
