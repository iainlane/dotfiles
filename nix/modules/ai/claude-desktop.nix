# Configure Claude Desktop with shared MCP servers; only valid on macOS.
{
  pkgs,
  inputs,
  lib,
  system,
  hostConfig,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Claude Desktop uses the same format as Claude Code.
  claudeDesktopMcpConfig = mcp.mkConfigFile "claude" "json" "claude_desktop_config.json";
in {
  # Claude Desktop is only available on Linux. The `or null` handles flake check
  # evaluation where `hostConfig` isn't in scope.
  config = lib.mkIf ((hostConfig.os or null) == "linux") {
    # Home Manager does not ship a programs.claude-desktop module (yet), so
    # install the app directly and drop in our config file.
    home.packages = [inputs.nix-ai-tools.packages.${system}.claude-desktop];

    # Claude Desktop expects a JSON file on disk, so stage the generated config.
    xdg.configFile."Claude/claude_desktop_config.json".source = claudeDesktopMcpConfig;
  };
}
