{
  config,
  lib,
  ...
}: let
  common = import ../../agentsview/common.nix {
    inherit lib;
    inherit (config.dotfiles) features;
  };
  server = common.serverSettings {
    inherit (config.dotfiles) hosts;
    inherit (config.dotfiles.agentsviewServer) domain;
  };
  pusherFor = hostConfig: (common.pushers config.dotfiles.hosts)."${hostConfig.name}-hermes";
in {
  dotfiles.features.hermes.agentsview = {
    includes = [config.dotfiles.features.hermes config.dotfiles.features.agentsview];
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
