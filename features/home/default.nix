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
  inherit (config.dotfiles) features;
  inherit (featureResolver) when;
  children = features.home;
in {
  imports = [
    ./debian
  ];

  dotfiles.features.home = {
    includes =
      [
        (when features.ai [
          features.ai.claude-code.teamclaude
          features.ai.cloudflare-mcp
        ])
        features.git
      ]
      ++ [
        (featureResolver.when featureResolver.isGenericLinux [children.debian])
      ];

    homeManager = ./home-manager.nix;
  };
}
