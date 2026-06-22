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
    # The agent's terminal working directory, inside the container.
    services.hermes-agent.settings.terminal.cwd = "/data/workspace";

    home.packages =
      [
        hostCliPackage
        pkgs.fuse-overlayfs
        pkgs.slirp4netns
      ]
      ++ cfg.extraPackages;

    services.podman = {
      enable = true;
      volumes = {
        ${hermesStateVolume} = {
          description = "Hermes Agent durable state";
        };
        ${hermesHomeVolume} = {
          description = "Hermes Agent home directory";
        };
        ${hermesCacheVolume} = {
          description = "Hermes Agent attachment cache, shared with signal-cli";
        };
      };
      images.${cfg.container.name} = {
        image = "docker-archive:${hermesImage}";
        autoStart = true;
      };
      containers.${cfg.container.name} = mkHermesContainer {
        description = "Hermes Agent Gateway";
        exec =
          lib.concatStringsSep " "
          (["gateway" "run" "--replace"] ++ cfg.extraArgs);
        network =
          lib.toList cfg.container.network
          ++ lib.optional cfg.signal.enable "${cfg.signal.network}.network"
          ++ lib.optional cfg.matrix.enable "${cfg.matrix.network}.network";
        # Start after the homeserver is healthy (it creates the bot account at
        # startup), so the agent's first Matrix login finds the account there.
        after = lib.optional cfg.matrix.enable "podman-${cfg.matrix.containerName}.service";
        ports = cfg.container.ports;
        service.TimeoutStopSec = 210;
      };
    };
  };
}
