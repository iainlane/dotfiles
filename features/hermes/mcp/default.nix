{
  flake.features.hermes.provides.mcp = {
    systemManager.imports = [./options.nix ./system-manager.nix];
  };
}
