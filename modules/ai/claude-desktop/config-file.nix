# The claude_desktop_config.json the app reads, rendered from the shared MCP
# server set, dropping any servers a profile has excluded for Claude Desktop.
{
  config,
  inputs,
  lib,
  pkgs,
  pkgs-unstable,
}: let
  mcp = import ../mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};

  servers =
    mcp.excludeServers config.dotfiles.claudeDesktop.excludeMcpServers
    config.dotfiles.ai.mcpServers;
in
  pkgs.writeText "claude_desktop_config.json" (
    builtins.toJSON {
      mcpServers = servers;
      preferences = {
        menuBarEnabled = false;
        coworkScheduledTasksEnabled = true;
        sidebarMode = "chat";
        coworkWebSearchEnabled = true;
      };
    }
  )
