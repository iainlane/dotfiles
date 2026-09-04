{
  flake.features.caddy.provides.origin-auth.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
