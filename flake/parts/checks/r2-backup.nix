# Checks the systemd settings the R2 backup library adds to a backup unit.
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

  assertions = [
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
    checks.r2-backup-scratch-directory =
      if failures == []
      then pkgs.runCommandLocal "r2-backup-scratch-directory" {} "touch $out"
      else throw "r2 backup scratch directory checks failed:\n${report}";
  };
}
