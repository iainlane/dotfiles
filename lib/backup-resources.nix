{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.backups;
in {
  options.dotfiles.backups.units = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Service units that share the background backup resource budget.";
  };

  config = lib.mkIf (cfg.units != []) {
    systemd = {
      slices.system-backup = {
        description = "Background backups";
        sliceConfig = {
          IOAccounting = true;
          CPUWeight = lib.mkDefault 20;
          IOWeight = lib.mkDefault 10;
        };
      };

      services = lib.genAttrs cfg.units (_: {
        serviceConfig = {
          Slice = "system-backup.slice";
          IOAccounting = true;
          Nice = lib.mkDefault 10;
        };
      });
    };
  };
}
