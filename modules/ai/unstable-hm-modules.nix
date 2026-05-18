# Import the AI-related home-manager program modules from unstable, even when
# the host is on the stable channel. These tools move fast enough that we always
# want the latest module options (enableMcpIntegration, skills, etc.).
{inputs, ...}: let
  hmPrograms = "${inputs.home-manager}/modules/programs";
in {
  disabledModules = [
    "programs/claude-code.nix"
    "programs/codex.nix"
    "programs/gemini-cli.nix"
    "programs/mcp.nix"
    "programs/opencode.nix"
  ];

  imports = map (f: import "${hmPrograms}/${f}") [
    "claude-code.nix"
    "codex.nix"
    "gemini-cli.nix"
    "mcp.nix"
    "opencode.nix"
  ];
}
