# The personal machines' Home Manager configuration.
#
# The `debian` child configures the Debian, Ubuntu and GNOME project
# directories on generic-linux hosts.
#
# `ai.claude-code.teamclaude` and `ai.cloudflare-mcp` configure options that
# `ai` declares, so `home` includes them only on a host that has `ai`.
{
  config,
  featureResolver,
  ...
}: let
  inherit (config.flake) features;
  inherit (featureResolver) when;
  children = features.home.provides;
in {
  imports = [
    ./debian
  ];

  flake.features.home = {
    includes =
      [
        (when features.ai [
          features.ai.provides.claude-code.provides.teamclaude
          features.ai.provides.cloudflare-mcp
        ])
        features.git
      ]
      ++ [
        (featureResolver.when featureResolver.isGenericLinux [children.debian])
      ];

    homeManager = ./home-manager.nix;
  };
}
