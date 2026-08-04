# The pieces a service needs to back itself up to Cloudflare R2: what it asks
# the host for, where the credentials come from, and the script that archives,
# encrypts and uploads. A service supplies the directory to archive and the
# schedule to do it on.
{
  # Options a service exposes for the host to fill in, as a submodule.
  options = {
    defaultPrefix,
    defaultSecretsFile,
  }: {lib, ...}: {
    options = {
      enable = lib.mkEnableOption "scheduled, encrypted backups to Cloudflare R2";

      secretsFile = lib.mkOption {
        type = lib.types.str;
        default = defaultSecretsFile;
        description = ''
          Path, relative to the `secrets` input, of the sops file holding
          `r2_bucket`, `r2_endpoint`, `r2_access_key_id`, and
          `r2_secret_access_key`. One bucket serves every backup, so the
          default is a file shared by everything decrypting with the same key.
        '';
      };

      ageRecipient = lib.mkOption {
        type = lib.types.str;
        example = "age1qz...";
        description = ''
          age public key the backup is encrypted to. Keep the matching private
          key offline; it is needed to restore.
        '';
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 04:00:00";
        description = "systemd `OnCalendar` schedule for the backup.";
      };

      keepDays = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = "Delete remote backups older than this many days.";
      };

      prefix = lib.mkOption {
        type = lib.types.str;
        default = defaultPrefix;
        description = "Path prefix within the R2 bucket.";
      };
    };
  };

  # The R2 credentials, as sops secrets and an environment file the upload
  # script reads them from.
  sopsFragment = {
    config,
    secretsFile,
    templateName,
  }: {
    secrets = {
      r2_bucket.sopsFile = secretsFile;
      r2_endpoint.sopsFile = secretsFile;
      r2_access_key_id.sopsFile = secretsFile;
      r2_secret_access_key.sopsFile = secretsFile;
    };

    templates.${templateName}.content = ''
      R2_BUCKET=${config.sops.placeholder.r2_bucket}
      R2_ENDPOINT=${config.sops.placeholder.r2_endpoint}
      R2_ACCESS_KEY_ID=${config.sops.placeholder.r2_access_key_id}
      R2_SECRET_ACCESS_KEY=${config.sops.placeholder.r2_secret_access_key}
    '';
  };

  uploader = {pkgs}:
    pkgs.writeShellApplication {
      name = "r2-upload";
      runtimeInputs = with pkgs; [age coreutils gnutar rclone zstd];
      text = builtins.readFile ./r2-upload.sh;
    };
}
