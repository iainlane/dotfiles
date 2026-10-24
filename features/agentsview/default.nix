{
  config,
  featureResolver,
  hostInventories,
  inputs,
  lib,
  ...
}: let
  topology = (import ./topology.nix {inherit lib;}) hostInventories;
in {
  imports = [./embeddings ./server-backup ./skills];
  _module.args.agentsviewTopology = topology;
  dotfiles = {
    inventorySchema = ./inventory-schema.nix;
    flakeSystem.includes = [config.dotfiles.features.agentsview];
    features = {
      agentsview = import ./client.nix {inherit config featureResolver inputs lib topology;};
      agentsview-server = import ./server.nix {inherit config inputs lib topology;};
    };
  };
}
