# The Hermes web dashboard: the same image and binary as the gateway, run with
# the `dashboard` sub-command in its own container.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
  inherit (import ./builders.nix {inherit config inputs lib pkgs;}) mkHermesContainer;
in {
  config = lib.mkIf (cfg.enable && cfg.dashboard.enable) {
    virtualisation.quadlet.containers.${cfg.dashboard.containerName} = mkHermesContainer {
      description = "Hermes Agent Web Dashboard";
      # Bound to the container's own loopback, so nothing on the network
      # reaches it. Hermes engages its auth gate on any other bind and
      # refuses to start without a provider, and it has no way to accept one
      # the proxy has already made. It joins the network for everything else
      # it talks to.
      exec = lib.concatStringsSep " " [
        "dashboard"
        "--host"
        cfg.dashboard.address
        "--port"
        (toString cfg.dashboard.port)
        "--no-open"
        "--skip-build"
      ];
      networks =
        lib.toList cfg.container.network
        ++ lib.optional cfg.signal.enable "${cfg.signal.network}.network";
      after = [
        "${cfg.container.name}.service"
      ];
    };
  };
}
