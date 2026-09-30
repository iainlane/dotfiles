# The personal machines' Home Manager configuration.
#
# The Linux half of it is the `debian` child, listed under `os.generic-linux`.
# That child sets up the Debian, Ubuntu and GNOME project directories. No NixOS
# host currently does that packaging work, so `home` has no `os.nixos.includes`
# entry; a host that needed one would list the same child there.
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
    includes = [
      (when features.ai [
        features.ai.provides.claude-code.provides.teamclaude
        features.ai.provides.cloudflare-mcp
      ])
      features.git
    ];

    os.generic-linux.includes = [children.debian];

    homeManager = ./home-manager.nix;
  };
}
