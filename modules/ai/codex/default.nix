# Configure Codex with system-wide defaults while leaving the home config free
# for interactive edits and per-instance overrides.
{
  flake.features.ai = {
    homeManager = ./home-manager.nix;
    system = ./system-config.nix;
  };
}
