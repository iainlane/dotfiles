{
  inputs,
  context,
  config,
  ...
}: let
  netboot = config.flake.lib.netboot {
    inherit
      context
      config
      ;
  };
in {
  # Re-export tools from flake inputs so the justfile can reference pinned
  # versions via `nix run .#<app>`.
  perSystem = {
    lib,
    pkgs,
    system,
    ...
  }: {
    apps =
      {
        deploy-rs = {
          type = "app";
          program = lib.getExe inputs.deploy-rs.packages.${system}.deploy-rs;
          meta.description = "Multi-profile Nix deployment tool";
        };
        nixos-anywhere = {
          type = "app";
          program = lib.getExe'
          inputs.nixos-anywhere.packages.${system}.nixos-anywhere
          "nixos-anywhere";
          meta.description = "Install NixOS on remote targets";
        };
      }
      // netboot.appsForSystem pkgs
      // lib.optionalAttrs (inputs.system-manager.packages ? ${system}) {
        system-manager = {
          type = "app";
          program = lib.getExe' inputs.system-manager.packages.${system}.default "system-manager";
          meta.description = "Non-NixOS system configuration manager";
        };
      };

    packages = netboot.packagesForSystem system;
  };
}
