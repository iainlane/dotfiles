{config, ...}: let
  inherit (config.flake) features halls;
in {
  flake.hosts.cripps = {
    os = "generic-linux";
    arch = "x86_64";
    motd = halls.cripps;
    features = [features.base];
  };
}
