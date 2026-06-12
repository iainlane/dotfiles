{
  config,
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ../mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
  instructions = import ../agent-instructions.nix {inherit lib;};
  skills = import ../skills.nix {inherit lib;};

  # Claude Code's `.mcp.json` schema: `type` of http/stdio plus `enabled`.
  mkMcpServer = server:
    (lib.removeAttrs server ["disabled"])
    // lib.optionalAttrs (server ? url) {type = "http";}
    // lib.optionalAttrs (server ? command) {type = "stdio";}
    // {enabled = !(server.disabled or false);};

  wrappedClaudeCode = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.claude-code;
    binName = "claude";
  };
in {
  options.dotfiles.claudeCode.excludeMcpServers = lib.mkOption {
    type = with lib.types; listOf str;
    default = [];
    description = ''
      Names of shared MCP servers to drop from Claude Code. The work profile
      uses this to exclude the enterprise connectors, which Claude Code
      receives from the organisation directly.
    '';
  };

  config = {
    programs.claude-code = {
      enable = true;
      package = wrappedClaudeCode;

      # Source the shared set directly rather than via `enableMcpIntegration`,
      # dropping any servers a profile has excluded for Claude Code.
      enableMcpIntegration = false;
      mcpServers =
        lib.mapAttrs (_name: mkMcpServer)
        (mcp.excludeServers config.dotfiles.claudeCode.excludeMcpServers config.dotfiles.ai.mcpServers);

      # Shared instructions as auto-loaded rule files.
      rules = instructions.files;

      # Shared skills from ./skills/.
      inherit skills;
    };

    xdg.configFile."ccstatusline/settings.json".source = pkgs.writeText "ccstatusline-settings.json" (builtins.toJSON (
      import ../ccstatusline.nix
    ));
  };
}
