{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.agentsviewServer.backup = (import ../../../lib/r2-backup.nix).options {
    inherit lib;
    defaultPrefix = "agentsview";
    defaultSecretsFile = "${hostConfig.name}/host-r2.yaml";
  };
}
