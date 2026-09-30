# Claude Code. The Home Manager module installs the package and the shared MCP
# servers. The settings go into system-level managed settings, so Claude Code
# can still write ~/.claude/settings.json when a setting is changed with
# `/config`.
#
# Claude Code looks for managed settings at OS-specific paths:
#   Linux: /etc/claude-code/managed-settings.json
#   macOS: /Library/Application Support/ClaudeCode/managed-settings.json
#
# On Linux, `environment.etc` writes to /etc, which is the right location. On
# macOS the target is under /Library, so an activation script symlinks the
# store path into place, which is the mechanism `environment.etc` uses itself.
{
  imports = [./teamclaude];

  flake.features.ai.provides.claude-code = {
    homeManager = ./home-manager.nix;
    # The managed-settings modules are registered for each class, not under
    # `system`. system-manager declares `system.activationScripts` with a
    # narrower type than nix-darwin, and it rejects the darwin definition even
    # inside `lib.mkIf false`.
    nixos = ./managed-settings-linux.nix;
    systemManager = ./managed-settings-linux.nix;
    darwin = ./managed-settings-darwin.nix;
  };
}
