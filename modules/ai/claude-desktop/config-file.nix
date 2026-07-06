# The claude_desktop_config.json the app reads, rendered from the shared MCP
# server set.
{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
}: let
  mcp = import ../mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
in
  pkgs.writeText "claude_desktop_config.json" (
    builtins.toJSON {
      mcpServers = mcp.servers;
      preferences = {
        menuBarEnabled = false;
        coworkScheduledTasksEnabled = true;
        sidebarMode = "chat";
        coworkWebSearchEnabled = true;
      };
    }
  )
