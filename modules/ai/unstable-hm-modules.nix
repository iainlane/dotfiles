# Import the AI-related home-manager program modules from unstable, even when
# the host is on the stable channel. These tools move fast enough that we always
# want the latest module options (enableMcpIntegration, skills, etc.).
{inputs, ...}: let
  hmPrograms = "${inputs.home-manager}/modules/programs";
in {
  # Stable still ships codex as a single `codex.nix`; unstable has moved it to a
  # `codex/` directory. Disable both so the host's own module is dropped on
  # either channel. Unmatched entries are ignored.
  disabledModules = [
    "programs/antigravity-cli.nix"
    "programs/claude-code.nix"
    "programs/codex.nix"
    "programs/codex"
    "programs/mcp.nix"
    "programs/opencode.nix"
  ];

  imports = map (f: import "${hmPrograms}/${f}") [
    "antigravity-cli.nix"
    "claude-code.nix"
    "codex"
    "mcp.nix"
    "opencode.nix"
  ];
}
