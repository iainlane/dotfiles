{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.unifi.backup = (import ../../../lib/r2-backup.nix).options {
    inherit lib;
    defaultPrefix = "unifi";
    defaultSchedule = "*-*-* 05:00:00";
    defaultSecretsFile = "${hostConfig.name}/host-r2.yaml";
    defaultVerifySchedule = "*-*-* 07:00:00";
  };
}
