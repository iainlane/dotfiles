{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.larapaper.backup = (import ../../../lib/r2-backup.nix).options {
    inherit lib;
    defaultPrefix = "larapaper";
    defaultSchedule = "*-*-* 01:00:00";
    defaultSecretsFile = "${hostConfig.name}/host-r2.yaml";
    defaultVerifySchedule = "*-*-* 05:40:00";
  };
}
