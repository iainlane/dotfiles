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
    services.podman.containers.${cfg.dashboard.containerName} = mkHermesContainer {
      description = "Hermes Agent Web Dashboard";
      # Host networking with a loopback bind: Hermes engages its auth gate on
      # any non-loopback bind and refuses to start without an auth provider.
      exec = lib.concatStringsSep " " [
        "dashboard"
        "--host"
        cfg.dashboard.address
        "--port"
        (toString cfg.dashboard.port)
        "--no-open"
        "--skip-build"
      ];
      network = ["host"];
      after = [
        "podman-${cfg.container.name}.service"
      ];
    };
  };
}
