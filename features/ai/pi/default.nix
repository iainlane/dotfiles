{config, ...}: {
  flake.features.ai.provides.pi = {
    checks = [./pi-theme-check.nix (import ./pi-startup-check.nix {inherit (config.flake) modelCatalog;})];
    homeManager = ./home-manager.nix;
  };
}
