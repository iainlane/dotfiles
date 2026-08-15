{
  config,
  inputs,
  lib,
  mcp,
  pkgs,
  system,
  ...
}: let
  # Claude Code receives the output styles natively (see `outputStyles`
  # below); `nativeOutputStyles` keeps the default style's body out of the
  # instruction files, so the model does not receive the same text twice.
  instructions = import ../agent-instructions.nix {
    inherit lib;
    nativeOutputStyles = true;
  };
  outputStyles = import ../output-styles.nix {inherit lib;};
  skills = import ../skills.nix {inherit inputs lib;};

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

      # Source the shared set directly, dropping any servers a profile has
      # excluded for Claude Code.
      enableMcpIntegration = false;
      mcpServers =
        lib.mapAttrs (_name: mkMcpServer)
        (mcp.excludeServers config.dotfiles.claudeCode.excludeMcpServers config.dotfiles.ai.mcpServers);

      # Shared instructions as auto-loaded rule files.
      rules = instructions.files;

      # Shared output styles from ../output-style/.
      outputStyles = outputStyles.files;

      # Shared skills from ./skills/.
      inherit skills;
    };

    xdg.configFile."ccstatusline/settings.json".source = pkgs.writeText "ccstatusline-settings.json" (builtins.toJSON (
      import ../ccstatusline {inherit pkgs lib;}
    ));
  };
}
