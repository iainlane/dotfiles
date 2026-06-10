# Import the AI-related home-manager program modules from unstable, even when
# the host is on the stable channel. These tools move fast enough that we always
# want the latest module options (enableMcpIntegration, skills, etc.).
{inputs, ...}: let
  hmPrograms = "${inputs.home-manager}/modules/programs";
in {
  # `gemini-cli.nix` only exists on the stable channel; unstable renamed it to
  # `antigravity-cli.nix`. Disabling both lets this work on either channel: the
  # stable module is dropped so it cannot clash with the rename shims that the
  # unstable `antigravity-cli.nix` declares for `programs.gemini-cli`, and a
  # disable for a module the channel does not ship is simply ignored.
  disabledModules = [
    "programs/antigravity-cli.nix"
    "programs/claude-code.nix"
    "programs/codex.nix"
    "programs/gemini-cli.nix"
    "programs/mcp.nix"
    "programs/opencode.nix"
  ];

  imports = map (f: import "${hmPrograms}/${f}") [
    "antigravity-cli.nix"
    "claude-code.nix"
    "codex.nix"
    "mcp.nix"
    "opencode.nix"
  ];
}
