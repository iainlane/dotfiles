# Scheduled, encrypted backups of the agent state to Cloudflare R2, driven by a
# systemd timer, with a timed check that they are arriving and a hand-run
# restore.
{
  config,
  hermesBuilders,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.hermes;
  secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
  inherit (hermesBuilders) hermesStateVolume;
  r2Backup = import ../../../lib/r2-backup.nix;
  r2Tool = r2Backup.tool {inherit pkgs;};
  envTemplate = "hermes-backup.env";
  # Nothing is substituted into the script, so it stays a plain shell file that
  # shellcheck can run over. Every setting arrives in the environment: the
  # systemd service supplies the non-secret values and the sops env file
  # supplies the R2 credentials.
  backupScript = pkgs.writeShellApplication {
    name = "hermes-backup-r2";
    runtimeInputs = with pkgs; [coreutils rsync sqlite podman r2Tool];
    text = builtins.readFile ./backup-r2.sh;
  };

  # The containers with the state volume mounted. A restore stops them for as
  # long as it takes to write over what they are reading.
  stateUnits =
    ["${cfg.container.name}.service"]
    ++ lib.optional cfg.dashboard.present "${cfg.dashboard.containerName}.service";

  # A restore is started by a person at a shell, so the script has the values
  # it needs baked in and reads the credentials from the sops env file itself.
  restoreScript = pkgs.writeShellApplication {
    name = "hermes-restore-r2";
    runtimeInputs = with pkgs; [coreutils findutils podman r2Tool rsync systemd];
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
  config = lib.mkMerge [
    {
      dotfiles.hermes.backup.present = true;

      assertions = r2Backup.assertions {
        inherit lib secretsFile;
        secretsPath = cfg.backup.secretsFile;
        subject = "The Hermes agent's state";
      };

      sops = r2Backup.sopsFragment {
        inherit config secretsFile;
        templateName = envTemplate;
      };

      environment.systemPackages = [restoreScript];

      systemd.services.hermes-backup = {
        description = "Back up Hermes state to Cloudflare R2";
        requires = ["sops-install-secrets.service"];
        after = ["network-online.target" "sops-install-secrets.service"];
        wants = ["network-online.target"];
        path = [config.virtualisation.podman.package r2Tool];
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

    {
      systemd = r2Backup.verifyUnits {
        inherit lib pkgs;
        inherit (cfg) backup;
        environmentFile = config.sops.templates.${envTemplate}.path;
        name = "hermes";
        subject = "Hermes";
      };
    }
  ];
}
