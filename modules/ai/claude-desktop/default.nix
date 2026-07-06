# Claude Desktop: the app itself on Linux (from pkgs/claude-desktop; macOS
# uses the Homebrew cask), plus its MCP configuration managed outside of
# llm-agents.
{
  flake.modules.ai.os = {
    darwin = {
      homeManagerModules = [./darwin.nix];
      systemManagerModules = [./system-manager.nix];
    };

    linux.homeManagerModules = [./linux.nix];
    nixos.homeManagerModules = [./linux.nix];
  };
}
