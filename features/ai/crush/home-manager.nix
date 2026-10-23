# Configure Crush CLI with the shared MCP servers, LSP and instructions.
{
  pkgs,
  config,
  inputs,
  instructions,
  lib,
  mcp,
  system,
  ...
}: let
  # Crush selects its MCP transport from the required `type` field.
  mkMcpServer = server:
    server
    // lib.optionalAttrs (server ? url) {type = "http";}
    // lib.optionalAttrs (server ? command) {type = "stdio";};

  # Crush expects its MCP servers and LSP config inside crush.json. Global
  # instructions are loaded via options.context_paths.
  crushConfig = pkgs.writeText "crush.json" (
    builtins.toJSON {
      "$schema" = "https://charm.land/crush.json";
      mcp = lib.mapAttrs (_name: mkMcpServer) config.dotfiles.ai.mcpServers;
      options.context_paths = ["~/.config/crush/AGENTS.md"];
    }
  );

  # Crush also scans `~/.claude/skills`, which contains Claude Code's variant
  # of each shared skill and Claude Code's own skills. `CRUSH_SKILLS_DIR`
  # replaces the whole list of global skill directories.
  wrappedCrush = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.crush;
    binName = "crush";
    extraWrapperArgs = [
      "--set"
      "CRUSH_SKILLS_DIR"
      "${config.home.homeDirectory}/.agents/skills"
    ];
  };
in {
  home.packages = [wrappedCrush];

  xdg.configFile = {
    "crush/crush.json".source = crushConfig;

    # Shared instructions for Crush to load via context_paths.
    "crush/AGENTS.md".text = instructions.concatenated;
  };
}
