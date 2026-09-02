# Scheduled, encrypted backups of the agent state to Cloudflare R2, driven by a
# systemd timer, with a timed check that they are arriving and a hand-run
# restore.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
  inherit (import ./builders.nix {inherit config inputs lib pkgs;}) hermesStateVolume;
  r2Backup = import ../../lib/r2-backup.nix;
  uploader = r2Backup.uploader {inherit pkgs;};
  verifier = r2Backup.verifier {inherit pkgs;};
  restorer = r2Backup.restorer {inherit pkgs;};
  envTemplate = "hermes-backup.env";
  # The script reads its config from the environment, so it stays a plain
  # checkable shell file. The systemd service supplies the non-secret values
  # and the sops env file supplies the R2 credentials.
  backupScript = pkgs.writeShellApplication {
    name = "hermes-backup-r2";
    runtimeInputs = with pkgs; [coreutils rsync sqlite podman uploader];
    text = builtins.readFile ./backup-r2.sh;
  };

  # The containers with the state volume mounted. A restore stops them for as
  # long as it takes to write over what they are reading.
  stateUnits =
    ["${cfg.container.name}.service"]
    ++ lib.optional cfg.dashboard.enable "${cfg.dashboard.containerName}.service";

  # A restore is started by a person at a shell, so the script carries the
  # values it needs and reads the credentials from the sops env file itself.
  restoreScript = pkgs.writeShellApplication {
    name = "hermes-restore-r2";
    runtimeInputs = with pkgs; [coreutils findutils podman restorer rsync systemd];
    runtimeEnv = {
      HERMES_STATE_VOLUME = hermesStateVolume;
      HERMES_RESTORE_UNITS = lib.concatStringsSep " " stateUnits;
      BACKUP_ENV_FILE = config.sops.templates.${envTemplate}.path;
      BACKUP_NAME = "hermes";
      BACKUP_PREFIX = cfg.backup.prefix;
    };
    text = builtins.readFile ./restore-r2.sh;
  };
in {
  config = lib.mkIf (cfg.enable && cfg.backup.enable) (lib.mkMerge [
    {
      sops = r2Backup.sopsFragment {
        inherit config;
        secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
        templateName = envTemplate;
      };

      environment.systemPackages = [restoreScript];

      systemd.services.hermes-backup = {
        description = "Back up Hermes state to Cloudflare R2";
        requires = ["sops-install-secrets.service"];
        after = ["network-online.target" "sops-install-secrets.service"];
        wants = ["network-online.target"];
        path = [config.virtualisation.podman.package uploader];
        serviceConfig = r2Backup.withScratchDirectory "hermes-backup" {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates.${envTemplate}.path;
          Environment = [
            "HERMES_STATE_VOLUME=${hermesStateVolume}"
            "BACKUP_NAME=hermes"
            "BACKUP_AGE_RECIPIENT=${cfg.backup.ageRecipient}"
            "BACKUP_PREFIX=${cfg.backup.prefix}"
            "BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
          ];
          ExecStart = "${backupScript}/bin/hermes-backup-r2";
        };
      };

      systemd.timers.hermes-backup = {
        description = "Schedule the Hermes R2 backup";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.backup.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };
    }

    (lib.mkIf cfg.backup.verify.enable {
      systemd.services.hermes-backup-verify = {
        description = "Check the Hermes R2 backup arrived";
        requires = ["sops-install-secrets.service"];
        after = ["network-online.target" "sops-install-secrets.service"];
        wants = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates.${envTemplate}.path;
          Environment = [
            "BACKUP_NAME=hermes"
            "BACKUP_PREFIX=${cfg.backup.prefix}"
            "BACKUP_MAX_AGE_HOURS=${toString cfg.backup.verify.maxAgeHours}"
            "BACKUP_MIN_SIZE=${toString cfg.backup.verify.minSizeBytes}"
            "BACKUP_MIN_COUNT=${toString cfg.backup.verify.minCount}"
          ];
          ExecStart = "${verifier}/bin/r2-verify";
        };
      };

      systemd.timers.hermes-backup-verify = {
        description = "Schedule the Hermes R2 backup check";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.backup.verify.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };
    })
  ]);
}
