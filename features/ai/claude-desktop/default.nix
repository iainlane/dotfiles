# Claude Desktop: the app itself on Linux (from llm-agents; macOS uses the
# Homebrew cask), plus its MCP configuration managed outside of llm-agents.
#
# `desktop` lists this child; `ai` does not, because a host can have `ai`
# without a graphical session. The child renders its configuration from
# `dotfiles.ai.mcpServers`, which `ai` declares, so it includes `ai`.
{config, ...}: {
  flake.features.ai.provides.claude-desktop = {
    includes = [config.flake.features.ai];

    darwin = ./darwin.nix;

    os = {
      darwin.homeManager = ./home-manager-darwin.nix;
      "generic-linux".homeManager = ./home-manager-linux.nix;
      nixos.homeManager = ./home-manager-linux.nix;
    };
  };
}
