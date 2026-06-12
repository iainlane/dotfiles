# Configure Claude Code: home-manager module for the package and shared MCP
# integration, plus system-level managed settings so that
# ~/.claude/settings.json can be written using `/config` etc.
#
# Claude Code looks for managed settings at OS-specific paths:
#   Linux: /etc/claude-code/managed-settings.json
#   macOS: /Library/Application Support/ClaudeCode/managed-settings.json
#
# On Linux, `environment.etc` maps directly to /etc which is the right
# location. On macOS the target is /Library (not /etc), so we symlink the
# store path into place via an activation script — the same mechanism that
# `environment.etc` itself uses under the hood.
{
  flake.modules.ai = {
    homeManagerModules = [./home-manager.nix];
    # Managed settings file is placed per-OS. Linux (both NixOS and
    # system-manager) uses environment.etc; darwin uses an activation-script
    # symlink into /Library. Splitting the two avoids feeding the darwin
    # branch to system-manager-linux, whose `system.activationScripts` is
    # narrower than nix-darwin's and rejects the definition even under
    # `lib.mkIf false`.
    nixosModules = [./managed-settings-linux.nix];
    os.linux.systemManagerModules = [./managed-settings-linux.nix];
    os.darwin.systemManagerModules = [./managed-settings-darwin.nix];
  };
}
