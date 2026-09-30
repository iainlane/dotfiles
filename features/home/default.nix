# The personal machines' Home Manager configuration.
#
# The Linux half of it is the `debian` child, listed under `os.generic-linux`.
# That child sets up the Debian, Ubuntu and GNOME project directories. No NixOS
# host currently does that packaging work, so `home` has no `os.nixos.includes`
# entry; a host that needed one would list the same child there.
#
# `ai.cloudflare-mcp` configures options that `ai` declares, so `home`
# includes it only on a host that has `ai`.
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
        features.ai.provides.cloudflare-mcp
      ])
      features.git
    ];

    os.generic-linux.includes = [children.debian];

    homeManager = ./home-manager.nix;
  };
}
