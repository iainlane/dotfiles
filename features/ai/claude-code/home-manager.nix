{
  config,
  inputs,
  instructions,
  lib,
  mcp,
  outputStyles,
  pkgs,
  skillTree,
  system,
  ...
}: let
  # Claude Code receives the output styles natively (see `outputStyles`
  # below), so its instruction set leaves the default style's body out of
  # the rule files and the model does not receive the same text twice.
  claudeCodeInstructions = instructions.harnesses.claudeCode;

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
  options.dotfiles.claudeCode = {
    excludeMcpServers = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      description = ''
        Names of shared MCP servers to drop from Claude Code. The work feature
        uses this to exclude the enterprise connectors, which Claude Code
        receives from the organisation directly.
      '';
    };

    skills = lib.mkOption {
      type = with lib.types; attrsOf (either path str);
      default = {};
      description = ''
        Skills for Claude Code only, in the form of `dotfiles.ai.skills`.
        They are merged over the shared set by key, so a feature can give
        Claude Code its own variant of a shared skill.
      '';
    };
  };

  config = {
    programs.claude-code = {
      enable = true;
      package = wrappedClaudeCode;

      # Source the shared set directly, dropping any servers a feature has
      # excluded for Claude Code.
      enableMcpIntegration = false;
      mcpServers =
        lib.mapAttrs (_name: mkMcpServer)
        (mcp.excludeServers config.dotfiles.claudeCode.excludeMcpServers config.dotfiles.ai.mcpServers);

      # Shared instructions as auto-loaded rule files.
      rules = claudeCodeInstructions.files;

      # Shared output styles from ../output-style/.
      outputStyles = outputStyles.files;
    };

    home.file."${config.programs.claude-code.configDir}/skills" = {
      source = skillTree (config.dotfiles.ai.skills // config.dotfiles.claudeCode.skills);
      recursive = true;
    };

    xdg.configFile."ccstatusline/settings.json".source =
      (pkgs.formats.json {}).generate "ccstatusline-settings.json"
      (import ./ccstatusline {inherit pkgs lib;});
  };
}
