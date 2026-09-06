# The `nix run .#<app>` entry points: the tools the justfile runs at pinned
# versions, whether they come from a flake input or from `pkgs/`, and the
# netboot installer and server for each NixOS host.
{
  inputs,
  config,
  lib,
  withSystem,
  ...
}: let
  nixosHosts = lib.filterAttrs (_: h: h.os == "nixos") config.flake.hosts;
  netboot = import ../../lib/netboot {inherit inputs;} {
    inherit
      config
      nixosHosts
      withSystem
      ;
  };
in {
  perSystem = {
    pkgs,
    pkgs-stable,
    system,
    ...
  }: {
    apps =
      {
        claude-prompt-conformance = {
          type = "app";
          program = lib.getExe pkgs.claude-prompt-conformance;
          meta.description = "Test Claude's assembled prompt configuration";
        };
        deploy-rs = {
          type = "app";
          program = lib.getExe inputs.deploy-rs.packages.${system}.deploy-rs;
          meta.description = "Multi-profile Nix deployment tool";
        };
        disko = {
          type = "app";
          program = lib.getExe inputs.disko.packages.${system}.disko;
          meta.description = "Partition, format and mount disks from a Nix description";
        };
        nixos-anywhere = {
          type = "app";
          program = lib.getExe'
          inputs.nixos-anywhere.packages.${system}.nixos-anywhere
          "nixos-anywhere";
          meta.description = "Install NixOS on remote targets";
        };
      }
      // netboot.appsForSystem {inherit pkgs;}
      // lib.optionalAttrs (inputs.system-manager.packages ? ${system}) {
        system-manager = {
          type = "app";
          program = lib.getExe' inputs.system-manager.packages.${system}.default "system-manager";
          meta.description = "Non-NixOS system configuration manager";
        };
      };

    packages = netboot.packagesForSystem {inherit pkgs pkgs-stable;};
  };
}
