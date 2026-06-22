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
  backupSecretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
  # The script reads its config from the environment, so it stays a plain
  # checkable shell file. The systemd service supplies the non-secret values
  # and the sops env file supplies the R2 credentials.
  backupScript = pkgs.writeShellApplication {
    name = "hermes-backup-r2";
    runtimeInputs = with pkgs; [coreutils rsync sqlite zstd gnutar rclone age podman];
    text = builtins.readFile ./backup-r2.sh;
  };
in {
  config = lib.mkIf (cfg.enable && cfg.backup.enable) {
    sops = {
      secrets = {
        r2_bucket.sopsFile = backupSecretsFile;
        r2_endpoint.sopsFile = backupSecretsFile;
        r2_access_key_id.sopsFile = backupSecretsFile;
        r2_secret_access_key.sopsFile = backupSecretsFile;
      };

      templates."hermes-backup.env".content = ''
        R2_BUCKET=${config.sops.placeholder.r2_bucket}
        R2_ENDPOINT=${config.sops.placeholder.r2_endpoint}
        R2_ACCESS_KEY_ID=${config.sops.placeholder.r2_access_key_id}
        R2_SECRET_ACCESS_KEY=${config.sops.placeholder.r2_secret_access_key}
      '';
    };

    systemd.user.services.hermes-backup = {
      Unit = {
        Description = "Back up Hermes state to Cloudflare R2";
        After = ["network-online.target" "sops-nix.service"];
        Wants = ["network-online.target"];
      };
      Service = {
        Type = "oneshot";
        EnvironmentFile = config.sops.templates."hermes-backup.env".path;
        Environment = [
          "HERMES_STATE_VOLUME=${hermesStateVolume}"
          "HERMES_BACKUP_AGE_RECIPIENT=${cfg.backup.ageRecipient}"
          "HERMES_BACKUP_PREFIX=${cfg.backup.prefix}"
          "HERMES_BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
        ];
        ExecStart = "${backupScript}/bin/hermes-backup-r2";
      };
    };

    systemd.user.timers.hermes-backup = {
      Unit.Description = "Schedule the Hermes R2 backup";
      Timer = {
        OnCalendar = cfg.backup.schedule;
        Persistent = true;
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
