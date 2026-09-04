# Scheduled uploads of the homeserver's own database backups to Cloudflare R2,
# with a timed check that they are arriving.
#
# The homeserver takes each backup itself when it receives SIGUSR2, which the
# timer below asks for, and writes it into the backup volume. This feature
# archives, encrypts and uploads what it finds there.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.matrix;

  paths = import ./paths.nix;

  unit = "${cfg.containerName}-backup";

  r2Backup = import ../../../lib/r2-backup.nix;
  r2Tool = r2Backup.tool {inherit pkgs;};

  backupScript = pkgs.writeShellApplication {
    name = "matrix-backup";
    runtimeInputs = [pkgs.coreutils];
    text = builtins.readFile ./backup.sh;
  };
in {
  config = {
    dotfiles.matrix.backup.present = true;

    sops = r2Backup.sopsFragment {
      inherit config;
      secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
      templateName = "matrix-backup.env";
    };

    virtualisation.quadlet.volumes.${paths.volume} = {};

    systemd = {
      services.${unit} = {
        description = "Back the Continuwuity database up to Cloudflare R2";
        requires = ["${cfg.containerName}.service" "sops-install-secrets.service"];
        after = ["${cfg.containerName}.service" "sops-install-secrets.service" "network-online.target"];
        wants = ["network-online.target"];
        path = [config.virtualisation.podman.package r2Tool];
        serviceConfig = r2Backup.withScratchDirectory unit {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates."matrix-backup.env".path;
          Environment = [
            "MATRIX_CONTAINER=${cfg.containerName}"
            "MATRIX_BACKUP_VOLUME=${paths.volume}"
            "MATRIX_BACKUP_TIMEOUT=${toString cfg.backup.timeout}"
            "BACKUP_NAME=${cfg.containerName}"
            "BACKUP_AGE_RECIPIENT=${cfg.backup.ageRecipient}"
            "BACKUP_PREFIX=${cfg.backup.prefix}"
            "BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
          ];
          ExecStart = "${backupScript}/bin/matrix-backup";
        };
      };

      timers.${unit} = {
        description = "Schedule the Continuwuity backup";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.backup.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };

      services."${unit}-verify" = lib.mkIf cfg.backup.verify.enable {
        description = "Check the Continuwuity R2 backup arrived";
        requires = ["sops-install-secrets.service"];
        after = ["network-online.target" "sops-install-secrets.service"];
        wants = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates."matrix-backup.env".path;
          Environment = [
            "BACKUP_NAME=${cfg.containerName}"
            "BACKUP_PREFIX=${cfg.backup.prefix}"
            "BACKUP_MAX_AGE_HOURS=${toString cfg.backup.verify.maxAgeHours}"
            "BACKUP_MIN_SIZE=${toString cfg.backup.verify.minSizeBytes}"
            "BACKUP_MIN_COUNT=${toString cfg.backup.verify.minCount}"
          ];
          ExecStart = "${r2Tool}/bin/r2 verify";
        };
      };

      timers."${unit}-verify" = lib.mkIf cfg.backup.verify.enable {
        description = "Schedule the Continuwuity backup check";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.backup.verify.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };
    };
  };
}
