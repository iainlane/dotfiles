{config, ...}: {
  flake.features.ai.provides.pi = {
    checks = [./pi-lens-check.nix ./pi-theme-check.nix ./session-footer-check.nix (import ./pi-startup-check.nix {inherit (config.flake) modelCatalog;})];
    homeManager = ./home-manager.nix;
  };
}
