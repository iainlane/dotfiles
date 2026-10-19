{
  flake.features.unifi.provides.backup.checks = [./unifi-backup-check.nix];
  flake.features.unifi.provides.backup.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
