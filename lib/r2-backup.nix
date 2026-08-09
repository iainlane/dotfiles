# The pieces a service needs to back itself up to Cloudflare R2: what it asks
# the host for, where the credentials come from, and the scripts that archive,
# encrypt and upload, check what arrived, and fetch it back. A service supplies
# the directory to archive and the schedule to do it on.
let
  # The public age key that backups are encrypted to. It is the same key on
  # every host. The matching private key is kept offline, and a restore needs
  # it.
  recipient = "age18peqyehsnk772uj60e35wathys8uxh9w0v9hxt6r9k92mqqhcajslmwcpg";
in {
  inherit recipient;

  # Options a service exposes for the host to fill in, as a submodule.
  options = {
    defaultPrefix,
    defaultSecretsFile,
  }: {lib, ...}: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to upload scheduled, encrypted backups to Cloudflare R2.
          This is on by default: a service holding state that cannot be
          rebuilt should be backed up as soon as a host runs it.
        '';
      };

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
        default = recipient;
        description = ''
          age public key the backup is encrypted to, defaulting to the shared
          one. Keep the matching private key offline; a restore needs it.
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

      verify = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Check on a timer that a backup reached the bucket. The private key
            is offline, so this looks at the remote objects alone: how old the
            newest one is, how big it is, and how many are held. A check that
            does not pass fails its unit.
          '';
        };

        schedule = lib.mkOption {
          type = lib.types.str;
          default = "*-*-* 06:00:00";
          description = ''
            systemd `OnCalendar` schedule for the check. It runs on a timer of
            its own so that a backup which never started is noticed as well,
            which means it wants to be an hour or two after `schedule`.
          '';
        };

        maxAgeHours = lib.mkOption {
          type = lib.types.int;
          default = 48;
          description = ''
            Fail if the newest backup in the bucket is older than this many
            hours. The default leaves a daily backup room to miss a single run
            before it counts as a problem.
          '';
        };

        minSizeBytes = lib.mkOption {
          type = lib.types.int;
          default = 65536;
          description = ''
            Fail if the newest backup is smaller than this many bytes, which
            catches an archive taken of an empty or half-mounted source.
          '';
        };

        minCount = lib.mkOption {
          type = lib.types.int;
          default = 1;
          description = ''
            Fail if the bucket holds fewer than this many backups. Raising it
            towards what `keepDays` should have accumulated checks that the
            history is there, and not only the newest copy.
          '';
        };
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

  # The check a host can make on backups it cannot open.
  verifier = {pkgs}:
    pkgs.writeShellApplication {
      name = "r2-verify";
      runtimeInputs = with pkgs; [coreutils jq rclone];
      text = builtins.readFile ./r2-verify.sh;
    };

  # The generic half of a restore: pick a backup, fetch it, open it with the
  # offline key. What to do with the result is the service's own business.
  restorer = {pkgs}:
    pkgs.writeShellApplication {
      name = "r2-restore";
      runtimeInputs = with pkgs; [age coreutils gnutar rclone zstd];
      text = builtins.readFile ./r2-restore.sh;
    };
}
