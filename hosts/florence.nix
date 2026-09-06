{config, ...}: let
  inherit (config.flake) features halls;
in {
  flake.hosts.florence = {
    hostname = "florence.local";
    os = "generic-linux";
    arch = "x86_64";
    motd = halls.florence;
    features = [
      features.base
      features.desktop
      features.development
      features.containers
      features.nixbuild-builder
      features.cloud
    ];
  };
}
