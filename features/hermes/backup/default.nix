{
  flake.features.hermes.provides.backup.checks = [./hermes-inbox-backup-check.nix];
  flake.features.hermes.provides.backup.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
