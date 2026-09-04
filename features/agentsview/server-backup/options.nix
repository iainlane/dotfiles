{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.agentsviewServer.backup = (import ../../../lib/r2-backup.nix).options {
    inherit lib;
    defaultPrefix = "agentsview";
    defaultSchedule = "*-*-* 02:00:00";
    defaultSecretsFile = "${hostConfig.name}/host-r2.yaml";
    defaultVerifySchedule = "*-*-* 06:00:00";
  };
}
