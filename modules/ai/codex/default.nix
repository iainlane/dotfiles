# Configure Codex with the shared MCP servers. Use a system-level managed
# configuration file, so that user changes can be written to the file under the
# home dir.
{
  flake.modules.ai = {
    homeManagerModules = [./home-manager.nix];
    systemManagerModules = [./managed-config.nix];
    nixosModules = [./managed-config.nix];
  };
}
