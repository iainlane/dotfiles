# Checks the R2 backup library's option defaults, its sops secret declarations
# and credential template, and the systemd settings that it adds to a backup
# unit.
#
# Each assertion is a `{ name; pass; }` attribute set so the check can report
# all failures together.
{lib, ...}: let
  r2Backup = import ../../../lib/r2-backup.nix;

  serviceConfig = {
    Type = "oneshot";
    EnvironmentFile = "/run/secrets/rendered/example-backup.env";
    Environment = [
      "BACKUP_NAME=example"
      "BACKUP_PREFIX=example"
    ];
    ExecStart = "/nix/store/example/bin/example-backup";
  };

  # A feature splices the declarations under a root of its own, so evaluate
  # them the same way to read the defaults a host would see.
  backupSettings =
    (lib.evalModules {
      modules = [
        {
          options.backup = lib.mkOption {
            type = lib.types.submodule {
              options = r2Backup.options {
                inherit lib;
                defaultPrefix = "example";
                defaultSchedule = "*-*-* 03:00:00";
                defaultSecretsFile = "example/host-r2.yaml";
                defaultVerifySchedule = "*-*-* 06:20:00";
              };
            };
            default = {};
          };
        }
      ];
    })
    .config
    .backup;

  # sops replaces each placeholder while rendering the template, so a stub
  # that spells the key out shows which value reaches which variable.
  sopsFragment = r2Backup.sopsFragment {
    config.sops.placeholder =
      lib.genAttrs r2Backup.credentialKeys (key: "<${key}>");
    secretsFile = "/secrets/example/host-r2.yaml";
    templateName = "example-backup.env";
  };

  assertions = [
    {
      name = "the option defaults come from the arguments the feature passes";
      pass =
        backupSettings
        == {
          secretsFile = "example/host-r2.yaml";
          ageRecipient = r2Backup.recipient;
          schedule = "*-*-* 03:00:00";
          keepDays = 30;
          prefix = "example";
          verify = {
            enable = true;
            schedule = "*-*-* 06:20:00";
            maxAgeHours = 48;
            minSizeBytes = 65536;
            minCount = 1;
          };
        };
    }
    {
      name = "every credential becomes a secret read from the service's sops file";
      pass =
        sopsFragment.secrets
        == lib.genAttrs r2Backup.credentialKeys (_: {
          sopsFile = "/secrets/example/host-r2.yaml";
        });
    }
    {
      name = "the rendered template gives each credential the name r2.sh reads";
      pass =
        sopsFragment.templates."example-backup.env".content
        == ''
          R2_BUCKET=<r2_bucket>
          R2_ENDPOINT=<r2_endpoint>
          R2_ACCESS_KEY_ID=<r2_access_key_id>
          R2_SECRET_ACCESS_KEY=<r2_secret_access_key>
        '';
    }
    {
      name = "a scratch directory is a cache directory named after the unit";
      pass = (r2Backup.withScratchDirectory "example-backup" serviceConfig).CacheDirectory == "example-backup";
    }
    {
      name = "TMPDIR points at the cache directory and the unit's own environment follows";
      pass =
        (r2Backup.withScratchDirectory "example-backup" serviceConfig).Environment
        == [
          "TMPDIR=%C/example-backup"
          "BACKUP_NAME=example"
          "BACKUP_PREFIX=example"
        ];
    }
    {
      name = "the other service settings are kept";
      pass =
        removeAttrs (r2Backup.withScratchDirectory "example-backup" serviceConfig) ["CacheDirectory" "Environment"]
        == removeAttrs serviceConfig ["Environment"];
    }
    {
      name = "a unit without an environment of its own gets TMPDIR alone";
      pass =
        (r2Backup.withScratchDirectory "example-backup" (removeAttrs serviceConfig ["Environment"])).Environment
        == ["TMPDIR=%C/example-backup"];
    }
  ];

  failures = lib.filter (assertion: !assertion.pass) assertions;
  report = lib.concatMapStringsSep "\n" (assertion: "  x ${assertion.name}") failures;
in {
  perSystem = {pkgs, ...}: {
    checks.r2-backup =
      if failures == []
      then pkgs.runCommandLocal "r2-backup" {} "touch $out"
      else throw "r2 backup library checks failed:\n${report}";
  };
}
