{
  config,
  agentsviewTopology,
  lib,
  ...
}: let
  common = import ../../agentsview/common.nix {inherit lib;};
in {
  dotfiles.features.hermes.agentsview = {
    includes = [config.dotfiles.features.hermes config.dotfiles.features.agentsview];
    inventory = ./inventory.nix;
    systemManager = [
      ./options.nix
      ({
        hostConfig,
        inputs,
        ...
      }: {
        _module.args.hermesAgentsview = {
          inherit common;
          inherit (agentsviewTopology) server;
          pusher = common.publisher inputs agentsviewTopology.hosts.${hostConfig.name}.publishers.hermes;
        };
      })
      ./system-manager.nix
    ];
  };
}
