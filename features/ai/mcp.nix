{config, ...}: {
  imports = [
    (import ./mcp-server-set.nix {})
  ];

  # Mirror the set into programs.mcp for upstream `enableMcpIntegration`
  # consumers (e.g. VS Code), which read it directly.
  config.programs.mcp = {
    enable = true;
    servers = config.dotfiles.ai.mcpServers;
  };
}
