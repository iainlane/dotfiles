# Scheduled, encrypted backups of the AgentsView database to Cloudflare R2,
# driven by a systemd timer, with a timed check that they are arriving.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.agentsview-server;

  database = import ./database.nix {inherit pkgs;};

  r2Backup = import ../../lib/r2-backup.nix;
  uploader = r2Backup.uploader {inherit pkgs;};
  verifier = r2Backup.verifier {inherit pkgs;};

  envTemplate = "agentsview-backup.env";

  backupName = "agentsview";

  # The script reads its config from the environment, so it stays a plain
  # checkable shell file. The systemd service supplies the non-secret values
  # and the sops env file supplies the R2 credentials.
  backupScript = pkgs.writeShellApplication {
    name = "agentsview-backup-r2";
    runtimeInputs = with pkgs; [coreutils podman uploader];
    text = builtins.readFile ./backup-r2.sh;
  };
in {
  config = lib.mkIf (cfg.enable && cfg.backup.enable) (lib.mkMerge [
    {
      sops = r2Backup.sopsFragment {
        inherit config;
        secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
        templateName = envTemplate;
      };

      systemd.services.agentsview-backup = {
        description = "Back up the AgentsView database to Cloudflare R2";
        requires = ["${database.containerName}.service" "sops-install-secrets.service"];
        after = [
          "${database.containerName}.service"
          "network-online.target"
          "sops-install-secrets.service"
        ];
        wants = ["network-online.target"];
        path = [config.virtualisation.podman.package uploader];

        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates.${envTemplate}.path;
          Environment = [
            "AGENTSVIEW_CONTAINER=${database.containerName}"
            "AGENTSVIEW_PG_DUMP=${database.package}/bin/pg_dump"
            "AGENTSVIEW_DATABASE=${cfg.database}"
            "AGENTSVIEW_SUPERUSER=${database.superuser}"
            "AGENTSVIEW_SOCKET_DIR=${database.socketDir}"
            "BACKUP_NAME=${backupName}"
            "BACKUP_AGE_RECIPIENT=${cfg.backup.ageRecipient}"
            "BACKUP_PREFIX=${cfg.backup.prefix}"
            "BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
          ];
          ExecStart = "${backupScript}/bin/agentsview-backup-r2";
        };
      };

      systemd.timers.agentsview-backup = {
        description = "Schedule the AgentsView R2 backup";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.backup.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };
    }

    (lib.mkIf cfg.backup.verify.enable {
      systemd.services.agentsview-backup-verify = {
        description = "Check the AgentsView R2 backup arrived";
        requires = ["sops-install-secrets.service"];
        after = ["network-online.target" "sops-install-secrets.service"];
        wants = ["network-online.target"];

        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates.${envTemplate}.path;
          Environment = [
            "BACKUP_NAME=${backupName}"
            "BACKUP_PREFIX=${cfg.backup.prefix}"
            "BACKUP_MAX_AGE_HOURS=${toString cfg.backup.verify.maxAgeHours}"
            "BACKUP_MIN_SIZE=${toString cfg.backup.verify.minSizeBytes}"
            "BACKUP_MIN_COUNT=${toString cfg.backup.verify.minCount}"
          ];
          ExecStart = "${verifier}/bin/r2-verify";
        };
      };

      systemd.timers.agentsview-backup-verify = {
        description = "Schedule the AgentsView backup check";
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
