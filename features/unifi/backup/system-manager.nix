# Scheduled, encrypted backups of the UniFi controller's state to Cloudflare
# R2, with a timed check that they are arriving.
#
# The site configuration and the adoption keys of every device live in the
# controller's mongodb database, and a rebuilt controller cannot reproduce
# them: every device would have to be adopted again.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.unifi;

  container = "unifi-os";

  unit = "unifi-backup";

  volumes = import ../volumes.nix;

  envTemplate = "unifi-backup.env";

  secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";

  r2Backup = import ../../../lib/r2-backup.nix;
  r2Tool = r2Backup.tool {inherit pkgs;};

  backupScript = pkgs.writeShellApplication {
    name = "unifi-backup-r2";
    runtimeInputs = with pkgs; [coreutils podman rsync systemd r2Tool];
    text = builtins.readFile ./backup.sh;
  };
in {
  config = lib.mkMerge [
    {
      assertions = r2Backup.assertions {
        inherit lib secretsFile;
        secretsPath = cfg.backup.secretsFile;
        subject = "The UniFi controller's state";
      };

      sops = r2Backup.sopsFragment {
        inherit config secretsFile;
        templateName = envTemplate;
      };

      systemd.services.${unit} = {
        description = "Back the UniFi controller's state up to Cloudflare R2";
        requires = ["sops-install-secrets.service"];
        after = ["network-online.target" "sops-install-secrets.service"];
        wants = ["network-online.target"];
        path = [config.virtualisation.podman.package r2Tool];

        serviceConfig = r2Backup.withScratchDirectory unit {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates.${envTemplate}.path;
          Environment = [
            "UNIFI_CONTAINER=${container}"
            "UNIFI_VOLUMES=${lib.concatMapStringsSep " " (mount: mount.volume) volumes.state}"
            "BACKUP_NAME=unifi"
            "BACKUP_AGE_RECIPIENT=${cfg.backup.ageRecipient}"
            "BACKUP_PREFIX=${cfg.backup.prefix}"
            "BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
          ];
          ExecStart = "${backupScript}/bin/unifi-backup-r2";
        };
      };

      systemd.timers.${unit} = {
        description = "Schedule the UniFi R2 backup";
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
        name = "unifi";
        subject = "UniFi";
      };
    }
  ];
}
