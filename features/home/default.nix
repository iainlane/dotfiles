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
