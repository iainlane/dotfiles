{
  flake.features.unifi.provides.backup.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
