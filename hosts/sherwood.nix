{config, ...}: let
  inherit (config.flake) features;
  halls = import ../lib/halls.nix;
in {
  flake.hosts.sherwood = {
    os = "linux";
    arch = "x86_64";
    motd = halls.sherwood;
    features = [
      features.base
      features.development
      features.containers
      features.nixbuild-builder
      features.desktop
      features.home
    ];

    homeModule = {
      dotfiles.git.signing.global.openpgp.key = "E352D5C51C5041D4";
    };
  };
}
