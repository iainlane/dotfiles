{
  inputs,
  lib,
  featureResolver,
  nixosHosts,
  config,
  withSystem,
}: let
  netboot = import ../../lib/netboot {inherit inputs featureResolver;} {
    inherit nixosHosts config withSystem;
  };
in {
  apps = {
    pkgs,
    system,
    ...
  }:
    {
      disko = {
        type = "app";
        program = lib.getExe inputs.disko.packages.${system}.disko;
        meta.description = "Partition, format and mount disks from a Nix description";
      };
      nixos-anywhere = {
        type = "app";
        program = lib.getExe' inputs.nixos-anywhere.packages.${system}.nixos-anywhere "nixos-anywhere";
        meta.description = "Install NixOS on remote targets";
      };
    }
    // netboot.appsForSystem {inherit pkgs;};

  packages = {
    pkgs,
    pkgs-stable,
    system,
    ...
  }:
    netboot.packagesForSystem {
      inherit pkgs pkgs-stable;
      inherit (featureResolver.contextForSystem system) platform;
    };
}
