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
      exec = lib.concatStringsSep " " [
        "dashboard"
        "--host"
        "0.0.0.0"
        "--port"
        (toString cfg.dashboard.port)
        "--no-open"
        "--insecure"
        "--skip-build"
      ];
      ports = ["${cfg.dashboard.address}:${toString cfg.dashboard.port}:${toString cfg.dashboard.port}"];
      after = [
        "podman-${cfg.container.name}.service"
      ];
    };
  };
}
