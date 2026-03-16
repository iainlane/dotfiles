# CrowdStrike Falcon sensor NixOS module.
# Falcon is fetched from a private GitHub release as a fixed-output derivation,
# then staged into /opt/CrowdStrike during activation so the upstream layout
# continues to work with the existing service wiring.
_: let
  nixosModule = {
    config,
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
      stringAfter
      types
      ;
    cfg = config.services.falcon-sensor;
    installDir = "/opt/CrowdStrike";
    hashKey =
      if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
      then "x86_64"
      else if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
      then "aarch64"
      else throw "Unsupported system for Falcon sensor: ${pkgs.stdenv.hostPlatform.system}";

    rpmArch =
      if hashKey == "x86_64"
      then "x86_64"
      else "aarch64";

    falconRelease =
      if cfg.release == null
      then null
      else
        cfg.release
        // {
          hash = cfg.release.hashes.${hashKey};
          rpmFilename = "falcon-sensor-${cfg.release.version}.el10.${rpmArch}.rpm";
          releaseTag = "v${cfg.release.version}";
        };

    fetchGitHubReleaseAsset = pkgs.callPackage ./fetch-github-release-asset.nix {};

    falconSensorPackage =
      if falconRelease == null
      then null
      else
        pkgs.stdenvNoCC.mkDerivation {
          pname = "falcon-sensor";
          inherit (falconRelease) version;
          src = fetchGitHubReleaseAsset {
            inherit (falconRelease) repo hash;
            tag = falconRelease.releaseTag;
            filename = falconRelease.rpmFilename;
          };
          nativeBuildInputs = with pkgs; [
            cpio
            patchelf
            rpm
          ];
          dontUnpack = true;
          installPhase = ''
            runHook preInstall

            mkdir -p "$out"
            extract_dir="$TMPDIR/extracted"
            mkdir -p "$extract_dir"
            cd "$extract_dir"
            rpm2cpio "$src" | cpio -idm --quiet

            cp -r opt "$out/"

            interp="$(patchelf --print-interpreter ${pkgs.bash}/bin/bash)"
            find "$out/opt/CrowdStrike" -maxdepth 1 -type f -perm -0100 -print0 | while IFS= read -r -d $'\0' binary; do
              patchelf --set-interpreter "$interp" "$binary" 2>/dev/null || true
            done

            runHook postInstall
          '';
        };

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

      release = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            repo = mkOption {
              type = types.str;
              description = "GitHub owner/repo containing Falcon release assets.";
            };
            version = mkOption {
              type = types.str;
              description = "Falcon sensor version to install.";
            };
            hashes = mkOption {
              type = types.attrsOf types.str;
              description = "Architecture-specific fixed-output hashes for the Falcon RPM.";
            };
          };
        });
        default = null;
        description = "Pinned Falcon release metadata.";
      };
    };

    config = mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.release != null;
          message = "services.falcon-sensor.release must be set.";
        }
      ];

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

      system.activationScripts.falcon-sensor-install = stringAfter ["users"] ''
        echo "staging CrowdStrike Falcon into ${installDir}..."
        mkdir -p ${installDir}
        ${pkgs.rsync}/bin/rsync -a --delete \
          ${falconSensorPackage}/opt/CrowdStrike/ \
          ${installDir}/
        chown -R root:root ${installDir}
        chmod -R 0750 ${installDir}
      '';

      systemd.services.falcon-sensor = {
        description = "CrowdStrike Falcon Sensor";
        after = ["local-fs.target" "network.target" "sops-nix.service"];
        wantedBy = ["multi-user.target"];
        conflicts = ["shutdown.target"];
        before = ["shutdown.target"];

        unitConfig.ConditionPathExists = "${installDir}/falcond";

        serviceConfig = {
          ExecStartPre = [falconStartPre];
          ExecStart = "${installDir}/falcond";
          Type = "forking";
          PIDFile = "/run/falcond.pid";
          Restart = "on-failure";
          RestartSec = "10s";
          TimeoutStopSec = "60s";
          KillMode = "control-group";
          KillSignal = "SIGTERM";
          Environment = ["LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib"];
          ReadWritePaths = [installDir "/var/log" "/run/secrets"];
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
  };
in {
  flake.modules.falcon.nixosModules = [nixosModule];
}
