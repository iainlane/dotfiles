# Configure Codex with system-wide defaults while leaving the home config free
# for interactive edits and per-instance overrides.
{
  dotfiles.features.ai.codex = {
    homeManager = ./home-manager.nix;
    system = ./system-config.nix;
  };
}
