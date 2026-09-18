# Scheduled, encrypted backups of the LaraPaper database and generated images
# to Cloudflare R2, driven by a systemd timer, with a timed check that they are
# arriving.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.larapaper;
  paths = import ../paths.nix;

  r2Backup = import ../../../lib/r2-backup.nix;
  r2Tool = r2Backup.tool {inherit pkgs;};

  envTemplate = "larapaper-backup.env";
  backupName = "larapaper";
  unit = "${backupName}-backup";

  secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";

  # Nothing is substituted into the script, so it stays a plain shell file that
  # shellcheck can run over.
  backupScript = pkgs.writeShellApplication {
    name = "larapaper-backup-r2";
    runtimeInputs = with pkgs; [coreutils podman rsync sqlite r2Tool];
    text = builtins.readFile ./backup-r2.sh;
  };
in {
  config = lib.mkMerge [
    {
      dotfiles.larapaper.backup.present = true;

      assertions = r2Backup.assertions {
        inherit lib secretsFile;
        secretsPath = cfg.backup.secretsFile;
        subject = "The LaraPaper database and generated images";
      };

      sops = r2Backup.sopsFragment {
        inherit config secretsFile;
        templateName = envTemplate;
      };

      systemd.services.${unit} = {
        description = "Back up LaraPaper to Cloudflare R2";
        requires = ["${cfg.containerName}.service" "sops-install-secrets.service"];
        after = [
          "${cfg.containerName}.service"
          "network-online.target"
          "sops-install-secrets.service"
        ];
        wants = ["network-online.target"];
        path = [config.virtualisation.podman.package r2Tool];

        serviceConfig = r2Backup.withScratchDirectory unit {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates.${envTemplate}.path;
          Environment = [
            "LARAPAPER_DATABASE_VOLUME=${paths.databaseVolume}"
            "LARAPAPER_STORAGE_VOLUME=${paths.storageVolume}"
            "LARAPAPER_DATABASE_FILE=${paths.databaseFile}"
            "BACKUP_NAME=${backupName}"
            "BACKUP_AGE_RECIPIENT=${cfg.backup.ageRecipient}"
            "BACKUP_PREFIX=${cfg.backup.prefix}"
            "BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
          ];
          ExecStart = "${backupScript}/bin/larapaper-backup-r2";
        };
      };

      systemd.timers.${unit} = {
        description = "Schedule the LaraPaper backup";
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
        subject = "LaraPaper";
      };
    }
  ];
}
