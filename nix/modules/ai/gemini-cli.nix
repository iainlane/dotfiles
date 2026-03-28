# Configure the Gemini CLI home-manager module with the shared MCP servers.
#
# The gemini-cli home-manager module does not have an `enableMcpIntegration`
# option, so we pass the shared MCP servers via `settings.mcpServers` directly.
{
  pkgs,
  config,
  inputs,
  lib,
  options,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};
  instructions = import ./agent-instructions.nix {inherit lib;};

  # Wrap Gemini CLI to add shared tools to PATH
  wrappedGemini = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.gemini-cli;
    binName = "gemini";
  };

  hasCatppuccinGeminiModule = options ? catppuccin && options.catppuccin ? gemini-cli;
in {
  config =
    {
      programs.gemini-cli = {
        enable = true;
        package = wrappedGemini;

        # Shared instructions as separate context files.
        context = instructions.files;

        settings = {
          mcpServers = config.programs.mcp.servers;
          context.fileName = map (n: "${n}.md") (lib.attrNames instructions.files);
        };
      };
    }
    // lib.optionalAttrs hasCatppuccinGeminiModule {
      catppuccin.gemini-cli.enable = true;
    };
}
