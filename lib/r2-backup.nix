# The pieces a service needs to back itself up to Cloudflare R2: what it asks
# the host for, where the credentials come from, and the tool that archives,
# encrypts and uploads, checks what arrived, and fetches it back. A service
# supplies the directory to archive and the schedule to do it on.
#
# `r2 restore` fetches and unpacks an archive; putting the contents back is
# each service's own business, and only Hermes wraps it in a command. Restoring
# the AgentsView database means feeding the dump to `psql`, Continuwuity's
# means putting the files back in its backup volume and telling it to load one,
# and UniFi's means stopping the container and writing the volumes back. Each
# is a hand-run job for a person with the offline key.
let
  # The public age key that backups are encrypted to. It is the same key on
  # every host. The matching private key is kept offline, and a restore needs
  # it.
  recipient = "age18peqyehsnk772uj60e35wathys8uxh9w0v9hxt6r9k92mqqhcajslmwcpg";

  # What the credentials file has to contain. The bucket is reached over S3
  # with a token scoped to that bucket, so all four values are needed.
  credentialKeys = [
    "r2_bucket"
    "r2_endpoint"
    "r2_access_key_id"
    "r2_secret_access_key"
  ];

  # Archives, checks, and restores: `r2 backup`, `r2 verify`, and
  # `r2 restore list|fetch`.
  tool = {pkgs}:
    pkgs.writeShellApplication {
      name = "r2";
      runtimeInputs = with pkgs; [age coreutils gnutar jq rclone zstd];
      text = builtins.readFile ./r2.sh;
    };
in {
  inherit credentialKeys recipient tool;

  # Options a service exposes for the host to fill in, as an attribute set of
  # declarations the backup feature splices under its own root.
  options = {
    defaultPrefix,
    defaultSchedule,
    defaultSecretsFile,
    defaultVerifySchedule,
    lib,
  }: {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = defaultSecretsFile;
      description = ''
        Path, relative to the `secrets` input, of the sops file that contains
        `r2_bucket`, `r2_endpoint`, `r2_access_key_id` and
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
      default = defaultSchedule;
      description = ''
        systemd `OnCalendar` schedule for the backup. Each service backing
        itself up to R2 has a default hour of its own: one host runs several
        of them, and `zstd -T0 -9` takes every core it is given.
      '';
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
          newest one is, how big it is, and how many there are. A check that
          does not pass fails its unit.
        '';
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = defaultVerifySchedule;
        description = ''
          systemd `OnCalendar` schedule for the check. It runs on a timer of
          its own, so a backup that never started is noticed as well. Set it
          an hour or two after `schedule`.
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
          Fail if the bucket contains fewer than this many backups. Raising it
          towards what `keepDays` should have accumulated checks that the
          history is there, and not only the newest copy.
        '';
      };
    };
  };

  # Check that the R2 credentials file exists and has every required key.
  # Without this, the failure comes at activation, as sops reporting a missing
  # file.
  assertions = {
    lib,
    secretsFile,
    secretsPath,
    subject,
  }: let
    lines =
      lib.optionals (builtins.pathExists secretsFile)
      (lib.splitString "\n" (builtins.readFile secretsFile));

    missing =
      lib.filter
      (key: !(lib.any (line: lib.hasPrefix "${key}:" line) lines))
      credentialKeys;
  in [
    {
      assertion = builtins.pathExists secretsFile;
      message = ''
        ${subject} is backed up to Cloudflare R2, and the secrets
        repository has no ${secretsPath}. Create it with these keys, one
        per line:
        ${lib.concatMapStringsSep "\n" (key: "  ${key}") credentialKeys}
      '';
    }

    {
      assertion = missing == [];
      message = ''
        ${subject} is backed up to Cloudflare R2, and ${secretsPath} is
        missing ${lib.concatStringsSep ", " missing}.
      '';
    }
  ];

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

  # Gives a backup unit a working directory on the root filesystem. Each
  # script builds its archive under `mktemp -d`, which honours TMPDIR. Left
  # to the default, the archive goes under /tmp, and on a host whose /tmp is
  # a tmpfs that puts the whole archive in RAM: a dump larger than the tmpfs
  # fails outright, and a smaller one crowds out the running services.
  withScratchDirectory = unitName: serviceConfig:
    serviceConfig
    // {
      CacheDirectory = unitName;
      Environment = ["TMPDIR=%C/${unitName}"] ++ serviceConfig.Environment or [];
    };

  # The timed check that a backup reached the bucket, as a `systemd` fragment
  # the service adds to its own configuration. Every service checks its own
  # archives the same way, so the units are written once here.
  #
  # `name` prefixes the units and selects the archives, and is the same
  # `BACKUP_NAME` the upload runs under.
  verifyUnits = {
    backup,
    environmentFile,
    lib,
    name,
    pkgs,
    subject,
  }: let
    unit = "${name}-backup-verify";
    r2 = tool {inherit pkgs;};
  in
    lib.mkIf backup.verify.enable {
      services.${unit} = {
        description = "Check the ${subject} R2 backup arrived";
        requires = ["sops-install-secrets.service"];
        after = ["network-online.target" "sops-install-secrets.service"];
        wants = ["network-online.target"];

        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = environmentFile;
          Environment = [
            "BACKUP_NAME=${name}"
            "BACKUP_PREFIX=${backup.prefix}"
            "BACKUP_MAX_AGE_HOURS=${toString backup.verify.maxAgeHours}"
            "BACKUP_MIN_SIZE=${toString backup.verify.minSizeBytes}"
            "BACKUP_MIN_COUNT=${toString backup.verify.minCount}"
          ];
          ExecStart = "${r2}/bin/r2 verify";
        };
      };

      timers.${unit} = {
        description = "Schedule the ${subject} backup check";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = backup.verify.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };
    };
}
