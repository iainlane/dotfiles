# Configure the Gemini CLI home-manager module with the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  options,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Wrap Gemini CLI to add shared tools to PATH
  wrappedGemini = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.gemini-cli;
    binName = "gemini";
  };

  hasGeminiModule = options ? programs && options.programs ? gemini-cli;
  hasCatppuccinGeminiModule = options ? catppuccin && options.catppuccin ? gemini-cli;
in {
  config =
    if hasGeminiModule
    then
      {
        programs.gemini-cli = {
          enable = true;
          package = wrappedGemini;
          settings.mcpServers = mcp.servers;
        };
      }
      // lib.optionalAttrs hasCatppuccinGeminiModule {
        catppuccin.gemini-cli.enable = true;
      }
    else {
      home.packages = [wrappedGemini];
    };
}
