{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  ...
}: let
  mcp = import ../mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};

  claudeDesktopConfig = pkgs.writeText "claude_desktop_config.json" (
    builtins.toJSON {
      mcpServers = mcp.servers;
      preferences = {
        menuBarEnabled = false;
        coworkScheduledTasksEnabled = true;
        sidebarMode = "chat";
        coworkWebSearchEnabled = true;
      };
    }
  );
in {
  home.file."Library/Application Support/Claude/claude_desktop_config.json" = {
    # The app itself seems to manage to clobber this file.
    force = true;
    source = claudeDesktopConfig;
  };
}
