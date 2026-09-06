{config, ...}: {
  flake.features.work.provides.claude-managed-settings = {
    # This child configures `dotfiles.claudeCode.managedSettings`, declared by
    # `ai.claude-code`, and the work MCP servers below configure `dotfiles.ai`,
    # declared by `ai`. `work` does not include this child, so a host can
    # select it on its own; it therefore includes `ai` itself.
    includes = [config.flake.features.ai];

    system = [
      ./mcp-servers.nix
      ./system.nix
    ];
  };
}
