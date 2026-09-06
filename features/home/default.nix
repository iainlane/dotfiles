# The personal machines' Home Manager configuration.
#
# The Linux half of it is the `debian` child, listed under `os.generic-linux`.
# That child sets up the Debian, Ubuntu and GNOME project directories. No NixOS
# host currently does that packaging work, so `home` has no `os.nixos.includes`
# entry; a host that needed one would list the same child there.
{config, ...}: let
  inherit (config.flake) features;
  children = features.home.provides;
in {
  imports = [
    ./debian
  ];

  flake.features.home = {
    includes = [features.ai.provides.cloudflare-mcp features.git];

    os.generic-linux.includes = [children.debian];

    homeManager = ./home-manager.nix;
  };
}
