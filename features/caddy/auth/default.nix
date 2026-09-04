{
  flake.features.caddy.provides.auth.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
