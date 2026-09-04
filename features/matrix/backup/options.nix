{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.matrix.backup =
    (import ../../../lib/r2-backup.nix).options {
      inherit lib;
      defaultPrefix = "matrix";
      defaultSchedule = "*-*-* 04:00:00";
      defaultSecretsFile = "${hostConfig.name}/host-r2.yaml";
      defaultVerifySchedule = "*-*-* 06:40:00";
    }
    // {
      keep = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = ''
          How many backups the homeserver retains on disk before deleting
          the oldest. Each is uploaded as it is taken; this is what stays
          locally.
        '';
      };

      timeout = lib.mkOption {
        type = lib.types.int;
        default = 1800;
        description = ''
          Seconds to wait for a backup to appear after asking for one,
          before giving up and failing the unit.
        '';
      };
    };
}
