{inputs}: {
  context,
  config,
}: let
  inherit
    (context)
    lib
    helpers
    nixosHosts
    overlays
    nixpkgsConfig
    ;

  mkHostNixpkgs = hostConfig:
    if (hostConfig.channel or "unstable") == "stable"
    then inputs.nixpkgs-stable
    else inputs.nixpkgs;

  mkNetbootInstaller = hostname: hostConfig: let
    hostSystem = helpers.mkSystem hostConfig;
    hostNixpkgs = mkHostNixpkgs hostConfig;
    hostPkgs = import hostNixpkgs {
      inherit overlays;
      system = hostSystem;
      config = nixpkgsConfig;
    };
    stateVersion = hostPkgs.lib.versions.majorMinor hostPkgs.lib.version;
    installer = hostNixpkgs.lib.nixosSystem {
      system = hostSystem;
      pkgs = hostPkgs;
      modules = [
        "${hostNixpkgs}/nixos/modules/installer/netboot/netboot-minimal.nix"
        ./netboot-installer.nix
        config.flake.nix.substitutersModule
        {
          networking.hostName = "${hostname}-installer";
          system.stateVersion = stateVersion;
        }
      ];
      specialArgs = {
        inherit inputs;
      };
    };
  in
    hostPkgs.linkFarm "${hostname}-netboot-installer" [
      {
        name = "bzImage";
        path = "${installer.config.system.build.kernel}/${installer.config.system.boot.loader.kernelFile}";
      }
      {
        name = "cmdline";
        path = hostPkgs.writeText "${hostname}-netboot-cmdline" (
          lib.concatStringsSep " " (
            [
              "init=${installer.config.system.build.toplevel}/init"
            ]
            ++ installer.config.boot.kernelParams
          )
        );
      }
      {
        name = "initrd";
        path = "${installer.config.system.build.netbootRamdisk}/initrd";
      }
      {
        name = "netboot.ipxe";
        path = "${installer.config.system.build.netbootIpxeScript}/netboot.ipxe";
      }
    ];

  mkIsoInstaller = hostname: hostConfig: let
    hostSystem = helpers.mkSystem hostConfig;
    hostNixpkgs = mkHostNixpkgs hostConfig;
    hostPkgs = import hostNixpkgs {
      inherit overlays;
      system = hostSystem;
      config = nixpkgsConfig;
    };
    stateVersion = hostPkgs.lib.versions.majorMinor hostPkgs.lib.version;
    hostToplevel = config.flake.nixosConfigurations.${hostname}.config.system.build.toplevel;
    installer = hostNixpkgs.lib.nixosSystem {
      system = hostSystem;
      pkgs = hostPkgs;
      modules = [
        "${hostNixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        ./netboot-installer.nix
        config.flake.nix.substitutersModule
        {
          networking.hostName = "${hostname}-installer";
          system.stateVersion = stateVersion;
          isoImage.storeContents = [hostToplevel];
        }
      ];
      specialArgs = {
        inherit inputs;
      };
    };
  in
    installer.config.system.build.isoImage;

  mkNetbootApp = pkgs: hostname: hostConfig: let
    hostSystem = helpers.mkSystem hostConfig;
    artifactAttr = "packages.${hostSystem}.${hostname}-netboot-installer";
  in {
    type = "app";
    program = lib.getExe (pkgs.writeShellApplication {
      name = "${hostname}-netboot";
      runtimeInputs = [
        pkgs.nix
        pkgs.pixiecore
      ];
      text = ''
        export NETBOOT_ARTIFACT_ATTR=${lib.escapeShellArg artifactAttr}
        export NETBOOT_BOOT_MESSAGE=${lib.escapeShellArg "Booting ${hostname} NixOS installer"}
        export NETBOOT_DISPLAY_NAME=${lib.escapeShellArg hostname}
        export NETBOOT_FLAKE_REF=${lib.escapeShellArg "path:${toString inputs.self}"}
        ${builtins.readFile ./netboot-server.bash}
      '';
    });
    meta.description = "Serve a PXE/netboot installer for ${hostname} via pixiecore";
  };
in {
  packagesForSystem = system: let
    systemHosts = lib.filterAttrs (_: hostConfig: helpers.mkSystem hostConfig == system) nixosHosts;
  in
    lib.mapAttrs'
    (
      hostname: hostConfig:
        lib.nameValuePair "${hostname}-netboot-installer" (mkNetbootInstaller hostname hostConfig)
    )
    systemHosts
    // lib.mapAttrs'
    (
      hostname: hostConfig:
        lib.nameValuePair "${hostname}-iso" (mkIsoInstaller hostname hostConfig)
    )
    systemHosts;

  appsForSystem = pkgs:
    lib.mapAttrs'
    (
      hostname: hostConfig:
        lib.nameValuePair "${hostname}-netboot" (mkNetbootApp pkgs hostname hostConfig)
    )
    nixosHosts;
}
