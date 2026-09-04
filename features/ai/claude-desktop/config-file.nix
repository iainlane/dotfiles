# The claude_desktop_config.json the app reads, rendered from the shared MCP
# server set, dropping any servers a profile has excluded for Claude Desktop.
{
  config,
  lib,
  mcp,
  pkgs,
}: let
  # Claude Desktop loads remote connectors from its account settings. Servers
  # managed through claude_desktop_config.json use its stdio interface.
  mkMcpServer = name: server:
    if server ? url
    then
      mcp.mcpRemote.mkServer {
        inherit name;
        inherit (server) url;
        headers = server.headers or {};
      }
    else server;

  servers = lib.mapAttrs mkMcpServer (
    mcp.excludeServers config.dotfiles.claudeDesktop.excludeMcpServers
    config.dotfiles.ai.mcpServers
  );
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
