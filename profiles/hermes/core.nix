# The Hermes Agent gateway itself: the durable state volumes, the agent image,
# and the long-running gateway container.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
  inherit
    (import ./builders.nix {inherit config inputs lib pkgs;})
    hostCliPackage
    hermesStateVolume
    hermesHomeVolume
    hermesCacheVolume
    hermesImage
    mkHermesContainer
    ;
in {
  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      [
        hostCliPackage
        pkgs.fuse-overlayfs
        pkgs.slirp4netns
      ]
      ++ cfg.extraPackages;

    services.hermes-agent.settings = {
      # The agent's terminal working directory, inside the container.
      terminal.cwd = "/data/workspace";

      # Single owner of the `plugins` allow/deny lists, merging the two
      # sources (context-engine's enable, host-level disables) into one
      # `settings.plugins` definition.
      plugins = lib.filterAttrs (_: v: v != []) {
        enabled = cfg.enabledPlugins;
        disabled = cfg.disabledPlugins;
      };
    };

    virtualisation.quadlet = {
      volumes = {
        ${hermesStateVolume} = {};
        ${hermesHomeVolume} = {};
        ${hermesCacheVolume} = {};
      };

      images.${cfg.container.name}.imageConfig = {
        image = "docker-archive:${hermesImage}";
        tag = "localhost/${cfg.container.name}:${hermesImage.imageTag}";
      };

      containers.${cfg.container.name} = mkHermesContainer {
        description = "Hermes Agent Gateway";
        exec =
          lib.concatStringsSep " "
          (["gateway" "run" "--replace"] ++ cfg.extraArgs);
        networks =
          lib.toList cfg.container.network
          ++ lib.optional cfg.signal.enable "${cfg.signal.network}.network";
        publishPorts = cfg.container.ports;
        serviceConfig.TimeoutStopSec = 210;
      };
    };
  };
}
