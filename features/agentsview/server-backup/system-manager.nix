# Scheduled, encrypted backups of the AgentsView database to Cloudflare R2,
# driven by a systemd timer, with a timed check that they are arriving.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.agentsviewServer;

  database = import ../server-database.nix {inherit pkgs;};

  r2Backup = import ../../../lib/r2-backup.nix;
  r2Tool = r2Backup.tool {inherit pkgs;};

  envTemplate = "agentsview-backup.env";

  backupName = "agentsview";

  # Nothing is substituted into the script, so it stays a plain shell file that
  # shellcheck can run over. Every setting arrives in the environment: the
  # systemd service supplies the non-secret values and the sops env file
  # supplies the R2 credentials.
  backupScript = pkgs.writeShellApplication {
    name = "agentsview-backup-r2";
    runtimeInputs = with pkgs; [coreutils podman r2Tool];
    text = builtins.readFile ./backup-r2.sh;
  };
  secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
in {
  config = lib.mkMerge [
    {
      dotfiles.agentsviewServer.backup.present = true;

      assertions = r2Backup.assertions {
        inherit lib secretsFile;
        secretsPath = cfg.backup.secretsFile;
        subject = "The AgentsView session database";
      };

      sops = r2Backup.sopsFragment {
        inherit config secretsFile;
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
        path = [config.virtualisation.podman.package r2Tool];

        serviceConfig = r2Backup.withScratchDirectory "agentsview-backup" {
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

    {
      systemd = r2Backup.verifyUnits {
        inherit lib pkgs;
        inherit (cfg) backup;
        environmentFile = config.sops.templates.${envTemplate}.path;
        name = backupName;
        subject = "AgentsView";
      };
    }
  ];
}
