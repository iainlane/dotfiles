{
  inputs,
  lib,
  deployPackageFor,
}: {
  apps = {system, ...}:
    {
      deploy-rs = {
        type = "app";
        program = lib.getExe (deployPackageFor system);
        meta.description = "Multi-profile Nix deployment tool";
      };
    }
    // lib.optionalAttrs (inputs.system-manager.packages ? ${system}) {
      system-manager = {
        type = "app";
        program = lib.getExe' inputs.system-manager.packages.${system}.default "system-manager";
        meta.description = "Non-NixOS system configuration manager";
      };
    };

  packages = {
    pkgs,
    system,
    ...
  }: {
    deploy-rs = deployPackageFor system;
    inherit (pkgs) nh;
  };
}
