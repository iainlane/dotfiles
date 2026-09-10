{
  config,
  lib,
  ...
}: let
  common = import ../../agentsview/common.nix {
    inherit lib;
    inherit (config.flake) features;
  };
  server = common.serverSettings {
    inherit (config.flake) hosts;
    inherit (config.flake.agentsviewServer) domain;
  };
  pusherFor = hostConfig: (common.pushers config.flake.hosts)."${hostConfig.name}-hermes";
in {
  flake.features.hermes.provides.agentsview = {
    includes = [config.flake.features.hermes config.flake.features.agentsview];
    systemManager = [
      ./options.nix
      ({hostConfig, ...}: {
        _module.args.hermesAgentsview = {
          inherit common server;
          pusher = pusherFor hostConfig;
        };
      })
      ./system-manager.nix
    ];
  };
}
