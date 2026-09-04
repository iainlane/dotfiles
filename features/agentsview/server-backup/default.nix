{
  flake.features.agentsview-server.provides.backup.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
