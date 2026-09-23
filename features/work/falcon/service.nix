# CrowdStrike Falcon sensor NixOS module.
# Falcon is staged into /opt/CrowdStrike when the service starts so the
# upstream layout continues to work with the existing service wiring.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    concatStringsSep
    mkEnableOption
    mkIf
    mkOption
    optionalString
    types
    ;
  cfg = config.services.falcon-sensor;
  installDir = "/opt/CrowdStrike";
  falconSensorPackage = inputs.secrets.packages.${pkgs.stdenv.hostPlatform.system}.falcon;

  # The sensor writes registration state into its install directory, so it
  # must run from a mutable copy of the package. Staging in
  # ExecStartPre ties the copy to a service restart: the store path embedded
  # in the unit changes with the package, so NixOS restarts the service and
  # the binaries are only ever replaced underneath a stopped daemon.
  falconInstall = pkgs.writeShellScript "falcon-install" ''
    set -euo pipefail

    echo "staging CrowdStrike Falcon into ${installDir}..."
    mkdir -p ${installDir}
    ${pkgs.rsync}/bin/rsync -a --delete \
      ${falconSensorPackage}/opt/CrowdStrike/ \
      ${installDir}/
    chown -R root:root ${installDir}
    chmod -R 0750 ${installDir}
  '';

  falconStartPre = pkgs.writeShellScript "falcon-start-pre" ''
    set -euo pipefail

    if [ -L /var/log/falconctl.log ]; then
      rm -f /var/log/falconctl.log
      touch /var/log/falconctl.log
      chmod 0640 /var/log/falconctl.log
    elif [ ! -f /var/log/falconctl.log ]; then
      touch /var/log/falconctl.log
      chmod 0640 /var/log/falconctl.log
    fi

    ${optionalString (cfg.cidFile != null) ''
      if [ -f "${cfg.cidFile}" ]; then
        CID="$(tr -d '[:space:]' < "${cfg.cidFile}")"
        if [ -n "$CID" ]; then
          echo "Setting CID..."
          "${installDir}/falconctl" -s --cid="$CID" -f
        else
          echo "WARNING: CID file exists but is empty: ${cfg.cidFile}"
        fi
      else
        echo "WARNING: CID file not found: ${cfg.cidFile}"
      fi
    ''}
    ${optionalString (cfg.tags != []) ''
      echo "Setting tags..."
      "${installDir}/falconctl" -s --tags="${concatStringsSep "," cfg.tags}" -f
    ''}
    ${optionalString (cfg.provisioningTokenFile != null) ''
      if [ -f "${cfg.provisioningTokenFile}" ]; then
        TOKEN="$(tr -d '[:space:]' < "${cfg.provisioningTokenFile}")"
        if [ -n "$TOKEN" ]; then
          echo "Setting provisioning token..."
          "${installDir}/falconctl" -s --provisioning-token="$TOKEN" -f
        else
          echo "WARNING: Provisioning token file exists but is empty: ${cfg.provisioningTokenFile}"
        fi
      else
        echo "WARNING: Provisioning token file not found: ${cfg.provisioningTokenFile}"
      fi
    ''}
    ${optionalString (cfg.traceLevel != null) ''
      echo "Setting trace level to ${cfg.traceLevel}..."
      "${installDir}/falconctl" -s --trace="${cfg.traceLevel}" -f
    ''}
    echo "Setting backend to bpf..."
    "${installDir}/falconctl" -s --backend=bpf -f
    "${installDir}/falconctl" -g --cid || true
  '';

  falconSensorCheck = pkgs.writeShellApplication {
    name = "falcon-sensor-check";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = builtins.readFile ./falcon-sensor-check.sh;
  };
in {
  options.services.falcon-sensor = {
    enable = mkEnableOption "CrowdStrike Falcon sensor";

    cidFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing the CrowdStrike Customer ID (CID).";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Sensor grouping tags for the CrowdStrike console.";
    };

    traceLevel = mkOption {
      type = types.nullOr (types.enum ["none" "err" "warn" "info" "debug"]);
      default = null;
      description = "Falcon sensor trace/logging verbosity level.";
    };

    provisioningTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing a provisioning token for sensor registration.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      falconSensorCheck
    ];

    programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [libnl];
    };

    systemd.tmpfiles.rules = [
      "d ${installDir} 0750 root root - -"
    ];

    systemd.services.falcon-sensor = {
      description = "CrowdStrike Falcon Sensor";
      after = ["local-fs.target" "network.target" "sops-install-secrets.service"];
      wantedBy = ["multi-user.target"];
      conflicts = ["shutdown.target"];
      before = ["shutdown.target"];

      serviceConfig = {
        ExecStartPre = [falconInstall falconStartPre];
        ExecStart = "${installDir}/falcond";
        Type = "forking";
        PIDFile = "/run/falcond.pid";
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStopSec = "60s";
        KillMode = "control-group";
        KillSignal = "SIGTERM";
        Environment = ["LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib"];
        MemorySwapMax = "0";
        OOMPolicy = "stop";
        ManagedOOMPreference = "avoid";
        Nice = 5;
        CPUSchedulingPolicy = "batch";
        CPUWeight = 80;
        IOWeight = 80;
      };
    };
  };
}
