# Claude Desktop: the app itself on Linux (from pkgs/claude-desktop; macOS
# uses the Homebrew cask), plus its MCP configuration managed outside of
# llm-agents.
{
  flake.features.ai = {
    darwin = ./system-manager.nix;
    os = {
      darwin.homeManager = ./darwin.nix;
      linux.homeManager = ./linux.nix;
      nixos.homeManager = ./linux.nix;
    };
  };
}
