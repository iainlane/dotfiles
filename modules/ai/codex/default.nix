# Configure Codex with system-wide defaults while leaving the home config free
# for interactive edits and per-instance overrides.
{
  flake.modules.ai = {
    homeManagerModules = [./home-manager.nix];
    systemManagerModules = [./system-config.nix];
    nixosModules = [./system-config.nix];
  };
}
