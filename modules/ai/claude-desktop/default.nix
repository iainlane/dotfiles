# Manage Claude Desktop's MCP configuration outside of llm-agents.
{
  flake.modules.ai.os.darwin.homeManagerModules = [./home-manager.nix];
  flake.modules.ai.os.darwin.systemManagerModules = [./system-manager.nix];
}
