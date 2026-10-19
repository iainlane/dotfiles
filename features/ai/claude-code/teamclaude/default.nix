# Routes Claude Code through TeamClaude, a local proxy that sends each request
# with the token of a Claude account that has quota left. A user service runs
# the proxy, and `claude` becomes a launcher that points Claude Code at it.
#
# Accounts are added with `teamclaude login`. Claude Code still needs its own
# login, and it uses that login directly while the proxy is not running.
{featureResolver, ...}: {
  flake.features.ai.provides.claude-code.provides.teamclaude = {
    checks = [./teamclaude-check.nix];
    includes = [
      (featureResolver.when featureResolver.isLinux [{homeManager = ./home-manager-linux.nix;}])
      (featureResolver.when featureResolver.isDarwin [{homeManager = ./home-manager-darwin.nix;}])
    ];
    homeManager = ./home-manager.nix;
  };
}
