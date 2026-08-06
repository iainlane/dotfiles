# Scheduled, encrypted backups of the agent state to Cloudflare R2, driven by a
# systemd timer.
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
  # The script reads its config from the environment, so it stays a plain
  # checkable shell file. The systemd service supplies the non-secret values
  # and the sops env file supplies the R2 credentials.
  backupScript = pkgs.writeShellApplication {
    name = "hermes-backup-r2";
    runtimeInputs = with pkgs; [coreutils rsync sqlite podman uploader];
    text = builtins.readFile ./backup-r2.sh;
  };
in {
  config = lib.mkIf (cfg.enable && cfg.backup.enable) {
    sops = r2Backup.sopsFragment {
      inherit config;
      secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
      templateName = "hermes-backup.env";
    };

    systemd.services.hermes-backup = {
      description = "Back up Hermes state to Cloudflare R2";
      requires = ["sops-install-secrets.service"];
      after = ["network-online.target" "sops-install-secrets.service"];
      wants = ["network-online.target"];
      path = [config.virtualisation.podman.package uploader];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.templates."hermes-backup.env".path;
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
  };
}
