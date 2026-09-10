# The Hermes Agent gateway itself: the durable state volumes, the agent image,
# and the long-running gateway container.
{
  config,
  exposePodman,
  hermesBuilders,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.hermes;
  inherit
    (hermesBuilders)
    hostCliPackage
    hermesStateVolume
    hermesHomeVolume
    hermesCacheVolume
    hermesImage
    mkHermesContainer
    ;

  gatewayContainer = mkHermesContainer {
    description = "Hermes Agent Gateway";
    exec = lib.concatStringsSep " " (["gateway" "run" "--replace"] ++ cfg.extraArgs);
    publishPorts = cfg.container.ports;

    # On stop the agent closes its platform connections, waits for the turn
    # in flight and writes its session state, and podman's own `stopTimeout`
    # then allows a further wait before the kill.
    serviceConfig.TimeoutStopSec = 210;
  };

  webhookExposed =
    cfg.webhook.present
    && cfg.webhook.active
    && cfg.webhook.expose != null
    && config.dotfiles.containers.edgeProxy.enable;
in {
  config = {
    environment.systemPackages = [hostCliPackage] ++ cfg.extraPackages;

    dotfiles.hermes = {
      agentPackages = [pkgs.curl pkgs.wget];

      settings = {
        # The agent's terminal working directory, inside the container.
        terminal = {
          cwd = "/data/workspace";
          home_mode = "real";
        };

        checkpoints.enabled = lib.mkDefault true;
        display.busy_input_mode = lib.mkDefault "steer";
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

      containers.${cfg.container.name} =
        if webhookExposed
        then exposePodman cfg.container.name gatewayContainer (cfg.webhook.expose // {inherit (cfg.webhook) port;})
        else gatewayContainer;
    };
  };
}
