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
    home.packages =
      [
        hostCliPackage
        pkgs.fuse-overlayfs
        pkgs.slirp4netns
      ]
      ++ cfg.extraPackages;

    services = {
      hermes-agent.settings = {
        # The agent's terminal working directory, inside the container.
        terminal.cwd = "/data/workspace";

        # Single owner of the `plugins` allow/deny lists so the two sources
        # (context-engine's enable, host-level disables) merge instead of one
        # `settings.plugins` definition clobbering the other.
        plugins = lib.filterAttrs (_: v: v != []) {
          enabled = cfg.enabledPlugins;
          disabled = cfg.disabledPlugins;
        };
      };

      podman = {
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
  };
}
