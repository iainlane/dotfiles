{
  flake.features.hermes.provides.embeddings.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
