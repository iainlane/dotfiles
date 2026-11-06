{config, ...}: let
  outputs = import ./outputs.nix {inherit (config.dotfiles) modelCatalog;};
in {
  dotfiles.flakeSystem.includes = [config.dotfiles.features.ai.pi];
  dotfiles.features.ai.pi = {
    checks = [./pi-theme-check.nix (import ./pi-startup-check.nix {inherit (config.dotfiles) modelCatalog;}) (import ./pi-bundle-check.nix {inherit (config.dotfiles) modelCatalog;})];
    apps = {
      inputs,
      pkgs,
      flakeContext,
      ...
    }:
      (outputs {inherit inputs pkgs flakeContext;}).apps;
    packages = {
      inputs,
      pkgs,
      flakeContext,
      ...
    }:
      (outputs {inherit inputs pkgs flakeContext;}).packages;
    homeManager = ./home-manager.nix;
  };
}
