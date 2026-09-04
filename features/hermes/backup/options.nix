{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.hermes.backup = (import ../../../lib/r2-backup.nix).options {
    inherit lib;
    defaultPrefix = "hermes";
    defaultSecretsFile = "${hostConfig.name}/host-r2.yaml";
  };
}
