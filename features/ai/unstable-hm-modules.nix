# Use unstable Home Manager's modules for the AI tools, including on hosts that
# follow the stable channel. The tools change faster than the stable channel,
# and the harness modules here are written against the unstable modules.
{inputs, ...}: let
  hmPrograms = "${inputs.home-manager}/modules/programs";
in {
  # Stable still ships codex as a single `codex.nix`; unstable has moved it to a
  # `codex/` directory. Disable both so the host's own module is dropped on
  # either channel. Unmatched entries are ignored.
  disabledModules = [
    "programs/antigravity-cli.nix"
    "programs/claude-code.nix"
    "programs/claude-code"
    "programs/codex.nix"
    "programs/codex"
    "programs/herdr.nix"
    "programs/mcp.nix"
    "programs/opencode.nix"
  ];

  # Import the modules explicitly. A path in `imports` keeps the module key
  # that `disabledModules` matches on, so listing the paths here would disable
  # these copies too and leave `programs.claude-code`, `programs.codex`,
  # `programs.herdr`, `programs.mcp` and `programs.opencode` undeclared.
  imports = map (f: import "${hmPrograms}/${f}") [
    "antigravity-cli.nix"
    "claude-code"
    "codex"
    "herdr.nix"
    "mcp.nix"
    "opencode.nix"
  ];
}
