# Configure GitHub Copilot CLI with the shared MCP servers and instructions.
#
# Note: upstream global instructions support
# (~/.copilot/copilot-instructions.md) is documented but buggy. We place the
# file anyway as best-effort.
{
  pkgs,
  config,
  inputs,
  lib,
  mcp,
  system,
  ...
}: let
  instructions = import ./agent-instructions.nix {inherit lib;};

  # Copilot requires an explicit transport for remote servers and a tool
  # selection for every server.
  mkMcpServer = server:
    (lib.removeAttrs server ["disabled"])
    // lib.optionalAttrs (server ? url) {type = "http";}
    // lib.optionalAttrs (server ? command) {type = "stdio";}
    // {tools = server.tools or ["*"];};

  enabledMcpServers =
    lib.filterAttrs (_name: server: !(server.disabled or false))
    config.dotfiles.ai.mcpServers;

  # Copilot CLI reads servers from a JSON file; generate it from the shared set.
  copilotMcpConfig = pkgs.writeText "mcp-config.json" (
    builtins.toJSON {
      servers = lib.mapAttrs (_name: mkMcpServer) enabledMcpServers;
    }
  );

  # Wrap Copilot CLI to add shared tools to PATH
  wrappedCopilot = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.copilot-cli;
    binName = "copilot";
  };
in {
  home.packages = [wrappedCopilot];

  home.file.".copilot/copilot-instructions.md".text = instructions.concatenated;

  # Point Copilot CLI at the generated config file.
  xdg.configFile."mcp-config.json".source = copilotMcpConfig;
}
