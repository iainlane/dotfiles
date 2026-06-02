# Configure OpenCode with the shared MCP servers.
{
  config,
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
  instructions = import ./agent-instructions.nix {inherit lib;};
  skills = import ./skills.nix {inherit lib;};

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

  # Wrap OpenCode to add shared tools to PATH
  wrappedOpencode = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.opencode;
    binName = "opencode";
  };
in {
  config = {
    programs.opencode = {
      enable = true;
      package = wrappedOpencode;

      context = instructions.concatenated;

      enableMcpIntegration = false;

      settings = {
        # Updates come from Nix, not opencode's self-updater.
        autoupdate = false;
        mcp = lib.mapAttrs (_name: mkMcpServer) config.dotfiles.ai.mcpServers;
      };

      tui.theme = "system";

      # Shared skills from ./skills/.
      inherit skills;
    };
  };
}
