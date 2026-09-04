{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.hermes.backup = (import ../../../lib/r2-backup.nix).options {
    inherit lib;
    defaultPrefix = "hermes";
    defaultSchedule = "*-*-* 03:00:00";
    defaultSecretsFile = "${hostConfig.name}/host-r2.yaml";
    defaultVerifySchedule = "*-*-* 06:20:00";
  };
}
