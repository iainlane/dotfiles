{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.unifi.backup =
    (import ../../../lib/r2-backup.nix).options {
      inherit lib;
      defaultPrefix = "unifi";
      defaultSchedule = "*-*-* 05:00:00";
      defaultSecretsFile = "${hostConfig.name}/host-r2.yaml";
      defaultVerifySchedule = "*-*-* 07:00:00";
    }
    // {
      statisticsDays = lib.mkOption {
        type = lib.types.int;
        default = 0;
        example = -1;
        description = ''
          Days of statistics to include in each backup, passed to the
          controller's backup command as its `days`. The default backs up the
          settings alone. These are enough to restore a rebuilt controller,
          and come to a few hundred kilobytes. `-1` includes the whole
          history, which is tens of megabytes even on a small site.
        '';
      };
    };
}
