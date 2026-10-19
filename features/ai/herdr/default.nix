# Herdr, a terminal workspace manager for coding agents. A user service runs
# the Herdr server, so panes and their agents keep running when the client
# detaches. Herdr's plugins are linked from the Nix store during activation.
#
# Herdr learns the session of each agent from hooks. The modules here add
# those hooks to every harness that the host has: to Claude Code's managed
# settings and Codex's system configuration, and as files in Pi's and
# OpenCode's configuration directories.
{
  config,
  featureResolver,
  ...
}: let
  harnesses = config.flake.features.ai.provides;

  # Whether the host has the `ai` child for `harness`, such as `claude-code`.
  hasHarness = hostConfig: harness: featureResolver.hasFeature hostConfig harnesses.${harness};
in {
  flake.features.ai.provides.herdr = {
    checks = [./herdr-check.nix];
    includes = [
      (featureResolver.when featureResolver.isLinux [{homeManager = ./home-manager-linux.nix;}])
      (featureResolver.when featureResolver.isDarwin [{homeManager = ./home-manager-darwin.nix;}])
    ];
    homeManager = import ./home-manager.nix {inherit hasHarness;};
    system = import ./system.nix {inherit hasHarness;};
  };
}
