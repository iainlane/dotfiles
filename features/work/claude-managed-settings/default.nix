{config, ...}: {
  flake.features.work.provides.claude-managed-settings = {
    # The managed settings define `dotfiles.claudeCode.managedSettings`, which
    # `ai.claude-code` declares, and the work MCP servers below reach
    # `dotfiles.ai`, which `ai` declares. `work` does not carry this child, so
    # it brings what declares those options itself.
    includes = [config.flake.features.ai];

    nixos = [
      ./mcp-servers.nix
      ./nixos.nix
    ];
  };
}
