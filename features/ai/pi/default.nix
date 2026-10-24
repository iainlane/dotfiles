{config, ...}: {
  dotfiles.flakeSystem.includes = [config.dotfiles.features.ai.pi];
  dotfiles.features.ai.pi = {
    checks = [./pi-theme-check.nix (import ./pi-startup-check.nix {inherit (config.dotfiles) modelCatalog;})];
    homeManager = ./home-manager.nix;
  };
}
