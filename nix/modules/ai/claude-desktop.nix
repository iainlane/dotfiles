# Manage Claude Desktop's MCP configuration outside of llm-agents.
_: let
  homeManagerModule = {
    pkgs,
    inputs,
    lib,
    ...
  }: let
    mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

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
    home.file."Library/Application Support/Claude/claude_desktop_config.json".source = claudeDesktopConfig;
  };

  systemManagerModule = {
    homebrew.casks = [
      "claude"
    ];
  };
in {
  flake.modules.ai.os.darwin.homeManagerModules = [homeManagerModule];
  flake.modules.ai.os.darwin.systemManagerModules = [systemManagerModule];
}
