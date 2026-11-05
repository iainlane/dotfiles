{
  inputs,
  lib,
}: {
  apps = {system, ...}:
    lib.optionalAttrs (inputs.system-manager.packages ? ${system}) {
      system-manager = {
        type = "app";
        program = lib.getExe' inputs.system-manager.packages.${system}.default "system-manager";
        meta.description = "Non-NixOS system configuration manager";
      };
    };

  packages = {pkgs, ...}: {
    inherit (pkgs) nh;
  };
}
