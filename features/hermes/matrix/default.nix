{
  flake.features.hermes.provides.matrix.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
