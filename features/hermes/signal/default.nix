{
  flake.features.hermes.provides.signal.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
