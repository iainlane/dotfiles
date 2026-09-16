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
  # Claude Code receives the default style's body twice on purpose: as an
  # output style (see `outputStyles` below) for the main agent, and as a rule
  # file for subagents, which run their own system prompt and are given no
  # output style.
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
        Names of shared MCP servers to drop from Claude Code. The other
        harnesses keep them. A name that is not in `dotfiles.ai.mcpServers`
        is an error. The work feature uses this to exclude the enterprise
        connectors, which Claude Code receives from the organisation
        directly.
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

    excludeSkills = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      description = ''
        Names of skills to leave out of Claude Code's skill tree. The other
        harnesses keep them. A name that matches no skill in the merged tree
        fails the build, and a name that `skills` also defines is an error.
      '';
    };
  };

  config = let
    cfg = config.dotfiles.claudeCode;

    definedAndExcluded = lib.intersectLists (lib.attrNames cfg.skills) cfg.excludeSkills;

    unknownMcpServers = lib.subtractLists (lib.attrNames config.dotfiles.ai.mcpServers) cfg.excludeMcpServers;
  in {
    assertions = [
      {
        assertion = definedAndExcluded == [];
        message = "dotfiles.claudeCode both defines and excludes these skills: ${lib.concatStringsSep ", " definedAndExcluded}";
      }
      {
        assertion = unknownMcpServers == [];
        message = "dotfiles.claudeCode.excludeMcpServers names servers that are not in dotfiles.ai.mcpServers: ${lib.concatStringsSep ", " unknownMcpServers}";
      }
    ];

    # Neither set is used from Claude Code: the built-in git tooling, the
    # Chrome extension and the bundled skills cover the same ground. The other
    # harnesses still receive them.
    dotfiles.claudeCode = {
      excludeMcpServers = ["context7" "git" "playwright"];
      excludeSkills = ["asd-ste100" "gh-stack" "stacked-prs"];
    };

    programs.claude-code = {
      enable = true;
      package = wrappedClaudeCode;

      # Source the shared set directly, dropping any servers a feature has
      # excluded for Claude Code.
      enableMcpIntegration = false;
      mcpServers =
        lib.mapAttrs (_name: mkMcpServer)
        (mcp.excludeServers cfg.excludeMcpServers config.dotfiles.ai.mcpServers);

      # Shared instructions as auto-loaded rule files.
      rules = claudeCodeInstructions.files;

      # Shared output styles from ../output-style/.
      outputStyles = outputStyles.files;
    };

    home.file."${config.programs.claude-code.configDir}/skills" = {
      source = skillTree {
        skills = config.dotfiles.ai.skills // cfg.skills;
        excludes = cfg.excludeSkills;
      };
      recursive = true;
    };

    xdg.configFile."ccstatusline/settings.json".source =
      (pkgs.formats.json {}).generate "ccstatusline-settings.json"
      (import ./ccstatusline {inherit pkgs lib;});
  };
}
