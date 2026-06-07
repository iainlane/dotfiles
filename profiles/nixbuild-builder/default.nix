{inputs, ...}: let
  nixbuild = import ../nixbuild-common.nix {inherit (inputs.nixpkgs) lib;};
in {
  flake.profiles.nixbuild-builder = {
    inherit (nixbuild) homeManagerModule;

    os = {
      darwin.systemManagerModule = _: {config, ...}: {
        imports = [
          nixbuild.darwinSystemManagerModule
        ];

        # Determinate Nix reads builders = @/etc/nix/machines by default.
        environment.etc."nix/machines".text =
          nixbuild.machineLines nixbuild.systems
          config.sops.secrets.nixbuild-private-key.path;
      };

      linux.systemManagerModule = _: {
        config,
        lib,
        pkgs,
        hostConfig,
        ...
      }: let
        x86Config = let
          targetSystem = "aarch64-linux";
          binfmtMagics = import (pkgs.path + "/nixos/lib/binfmt-magics.nix");
          targetMagic = binfmtMagics.${targetSystem};
          targetPlatform = lib.systems.elaborate {system = targetSystem;};
          interpreter = targetPlatform.emulator pkgs.pkgsStatic;
        in
          lib.mkIf (hostConfig.arch == "x86_64") {
            environment.etc."binfmt.d/aarch64-linux.conf".text = ":${targetSystem}:M::${targetMagic.magicOrExtension}:${targetMagic.mask}:${interpreter}:FPC";

            environment.systemPackages = [pkgs.pkgsStatic.qemu-user];

            nix.settings.extra-platforms = ["aarch64-linux"];
          };
      in {
        imports = [
          nixbuild.linuxSystemManagerModule
        ];

        config = lib.mkMerge [
          {
            environment.etc."nix/machines".text =
              nixbuild.machineLines nixbuild.systems
              config.sops.secrets.nixbuild-private-key.path;
          }
          x86Config
        ];
      };

      nixos.nixosModule = _: {
        config,
        lib,
        hostConfig,
        ...
      }: {
        imports = [
          nixbuild.nixosModule
        ];

        nix.distributedBuilds = true;
        nix.buildMachines =
          map (system: {
            hostName = nixbuild.builderAlias;
            inherit system;
            sshKey = config.sops.secrets.nixbuild-private-key.path;
            inherit (nixbuild) maxJobs speedFactor supportedFeatures;
          })
          nixbuild.systems;

        boot.binfmt.emulatedSystems = lib.mkIf (hostConfig.arch == "x86_64") ["aarch64-linux"];
      };
    };
  };
}
