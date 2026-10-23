# Configure OpenCode with the shared MCP servers.
{
  config,
  inputs,
  instructions,
  lib,
  mcp,
  system,
  ...
}: let
  # OpenCode's schema: `type` is remote/local, a local server's command and args
  # are a single list, and `env` becomes `environment`.
  mkMcpServer = server:
    {enabled = !(server.disabled or false);}
    // (
      if server ? url
      then
        {
          type = "remote";
          inherit (server) url;
        }
        // lib.optionalAttrs (server ? headers) {inherit (server) headers;}
      else
        {
          type = "local";
          command = [server.command] ++ (server.args or []);
        }
        // lib.optionalAttrs (server ? env) {environment = server.env;}
    );

  # OpenCode ignores `disable-model-invocation`. A `deny` rule for the skill
  # leaves it out of the skills listed to the model, and the user can still run
  # it as a command.
  modelHiddenSkills =
    lib.filterAttrs
    (_name: value: value ? skill && value.skill.frontmatter.disable-model-invocation)
    config.dotfiles.ai.skills;

  # Wrap OpenCode to add shared tools to PATH. OpenCode also scans
  # `~/.claude/skills`, which contains the same skills as `~/.agents/skills`
  # with Claude Code's variant of each, so that scan is switched off.
  wrappedOpencode = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.opencode;
    binName = "opencode";
    extraWrapperArgs = [
      "--set"
      "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS"
      "1"
    ];
  };
in {
  config = {
    programs.opencode = {
      enable = true;
      package = wrappedOpencode;

      context = instructions.concatenated;

      enableMcpIntegration = false;

      settings =
        {
          # Updates come from Nix, not opencode's self-updater.
          autoupdate = false;
          mcp = lib.mapAttrs (_name: mkMcpServer) config.dotfiles.ai.mcpServers;
        }
        // lib.optionalAttrs (modelHiddenSkills != {}) {
          permission.skill = lib.mapAttrs (_name: _: "deny") modelHiddenSkills;
        };

      tui.theme = "system";
    };
  };
}
