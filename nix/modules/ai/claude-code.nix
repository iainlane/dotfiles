# Configure Claude Code with the shared MCP servers.
#
# On stable home-manager the `programs.claude-code` option does not exist, so
# we fall back to installing the wrapped package directly.
{
  pkgs,
  inputs,
  lib,
  options,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Wrap Claude Code to add shared tools to PATH.
  wrappedClaudeCode = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.claude-code;
    binName = "claude";
  };

  hasClaudeCodeModule = options ? programs && options.programs ? claude-code;
in {
  config =
    if hasClaudeCodeModule
    then {
      programs.claude-code = {
        enable = true;
        package = wrappedClaudeCode;

        mcpServers = mcp.servers;
        settings = {
          alwaysThinkingEnabled = true;
          attribution = {
            commit = "";
            pr = "";
          };
          enabledPlugins = {
            "claude-code-setup@claude-plugins-official" = true;
            "claude-md-management@claude-plugins-official" = true;
            "code-review@claude-plugins-official" = true;
            "feature-dev@claude-plugins-official" = true;
            "frontend-design@claude-plugins-official" = true;
            "pr-review-toolkit@claude-plugins-official" = true;
            "ralph-loop@claude-plugins-official" = true;
            "security-guidance@claude-plugins-official" = true;
            # It seems to aggressively replace default behaviours.
            # "superpowers@claude-plugins-official" = true;
            "typescript-lsp@claude-plugins-official" = true;
          };
          env = {
            CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          };
          extraKnownMarketplaces = {
            "anthropic-agent-skills" = {
              source = {
                source = "github";
                repo = "anthropics/skills";
              };
            };
          };
          model = "opus";
          skipDangerousModePermissionPrompt = true;
          voiceEnabled = true;
        };
      };
    }
    else {
      home.packages = [wrappedClaudeCode];
    };
}
