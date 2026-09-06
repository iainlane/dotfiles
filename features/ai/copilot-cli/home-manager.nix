# Configure GitHub Copilot CLI with the shared MCP servers and instructions.
#
# Upstream documents a global instructions file at
# `~/.copilot/copilot-instructions.md`, but Copilot CLI does not reliably read
# it. The file is written anyway.
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

  wrappedCopilot = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.copilot-cli;
    binName = "copilot";
  };
in {
  home = {
    packages = [wrappedCopilot];

    file = {
      ".copilot/copilot-instructions.md".text = instructions.concatenated;
      ".copilot/mcp-config.json".source = copilotMcpConfig;
    };
  };
}
