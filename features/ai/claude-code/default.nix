# Configure Claude Code: home-manager module for the package and shared MCP
# integration, plus system-level managed settings so that
# ~/.claude/settings.json can be written using `/config` etc.
#
# Claude Code looks for managed settings at OS-specific paths:
#   Linux: /etc/claude-code/managed-settings.json
#   macOS: /Library/Application Support/ClaudeCode/managed-settings.json
#
# On Linux, `environment.etc` writes to /etc, which is the right location. On
# macOS the target is under /Library, so an activation script symlinks the
# store path into place, which is the mechanism `environment.etc` uses itself.
{
  flake.features.ai.provides.claude-code = {
    homeManager = ./home-manager.nix;
    # The two managed-settings modules are registered per class instead of
    # under `system`: system-manager's `system.activationScripts` is narrower
    # than nix-darwin's and rejects the darwin definition even under
    # `lib.mkIf false`.
    nixos = ./managed-settings-linux.nix;
    systemManager = ./managed-settings-linux.nix;
    darwin = ./managed-settings-darwin.nix;
  };
}
