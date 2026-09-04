{config, ...}: let
  halls = import ../lib/halls.nix;
in {
  flake.hosts.cripps = {
    os = "generic-linux";
    arch = "x86_64";
    motd = halls.cripps;
    features = [config.flake.features.base];
  };
}
