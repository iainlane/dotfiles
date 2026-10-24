{config, ...}: let
  inherit (config.dotfiles) features halls;
in {
  dotfiles.hosts.cripps = {
    os = "generic-linux";
    arch = "x86_64";
    motd = halls.cripps;
    features = [features.base];
  };
}
