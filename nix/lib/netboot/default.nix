{inputs}: {
  config,
  nixosHosts,
  overlays,
  nixpkgsConfig,
}: let
  inherit (inputs.nixpkgs) lib;

  mkHostNixpkgs = hostConfig:
    if hostConfig.channel == "stable"
    then inputs.nixpkgs-stable
    else inputs.nixpkgs;

  # Select the pre-computed pkgs matching a host's channel.
  pkgsForHost = pkgs: pkgs-stable: hostConfig:
    if hostConfig.channel == "stable"
    then pkgs-stable
    else pkgs;

  mkNetbootInstaller = hostPkgs: hostname: hostConfig: let
    hostNixpkgs = mkHostNixpkgs hostConfig;
    stateVersion = hostPkgs.lib.versions.majorMinor hostPkgs.lib.version;
    installer = hostNixpkgs.lib.nixosSystem {
      inherit (hostConfig) system;
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

  mkIsoInstallerConfig = hostPkgs: hostname: hostConfig: let
    hostNixpkgs = mkHostNixpkgs hostConfig;
    stateVersion = hostPkgs.lib.versions.majorMinor hostPkgs.lib.version;
    hostToplevel = config.flake.nixosConfigurations.${hostname}.config.system.build.toplevel;
  in {
    inherit hostNixpkgs hostPkgs;
    installer = hostNixpkgs.lib.nixosSystem {
      inherit (hostConfig) system;
      pkgs = hostPkgs;
      modules = [
        "${hostNixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        ./netboot-installer.nix
        config.flake.nix.substitutersModule
        {
          networking.hostName = "${hostname}-installer";
          system.stateVersion = stateVersion;
          isoImage.storeContents = [hostToplevel];
          isoImage.makeBiosBootable = false;
        }
      ];
      specialArgs = {
        inherit inputs;
      };
    };
  };

  # All x86_64-linux inputs needed by the ISO assembly. Building this
  # derivation ensures the entire closure is materialised in the store.
  mkIsoContents = hostPkgs: hostname: hostConfig: let
    evaluated = mkIsoInstallerConfig hostPkgs hostname hostConfig;
    installerConfig = evaluated.installer.config;
    contentSources =
      lib.imap0 (i: x: {
        name = "content-${toString i}";
        path = x.source;
      })
      installerConfig.isoImage.contents;
    storePaths =
      lib.imap0 (i: p: {
        name = "store-${toString i}";
        path = p;
      })
      installerConfig.isoImage.storeContents;
  in
    evaluated.hostPkgs.linkFarm "${hostname}-iso-contents"
    (contentSources ++ storePaths);

  # Build an ISO on `buildSystem` for the target host. The host and build
  # systems may differ (e.g. building on aarch64-darwin for x86_64-linux),
  # so hostPkgs is instantiated for the target while buildPkgs is for the
  # local machine.
  mkLocalIso = {
    buildPkgs,
    hostPkgs,
  }: hostname: hostConfig: let
    evaluated = mkIsoInstallerConfig hostPkgs hostname hostConfig;
    installerConfig = evaluated.installer.config;
  in
    buildPkgs.callPackage "${evaluated.hostNixpkgs}/nixos/lib/make-iso9660-image.nix" {
      inherit (installerConfig.isoImage) compressImage volumeID contents;
      bootable = false;
      efiBootImage = "boot/efi.img";
      efiBootable = true;
      inherit (installerConfig.isoImage) squashfsCompression;
      isoName = "${installerConfig.image.baseName}.iso";
      isohybridMbrImage = "${evaluated.hostPkgs.syslinux}/share/syslinux/isohdpfx.bin";
      squashfsContents = installerConfig.isoImage.storeContents;
      syslinux = null;
      usbBootable = true;
    };

  mkNetbootApp = pkgs: hostname: hostConfig: let
    artifactAttr = "packages.${hostConfig.system}.${hostname}-netboot-installer";
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

  # Create host pkgs for a potentially different system than the current
  # one (needed for cross-system ISO builds).
  mkHostPkgs = hostConfig:
    import (mkHostNixpkgs hostConfig) {
      inherit overlays;
      inherit (hostConfig) system;
      config = nixpkgsConfig;
    };
in {
  packagesForSystem = {
    pkgs,
    pkgs-stable,
  }: let
    inherit (pkgs.stdenv.hostPlatform) system;
    systemHosts = lib.filterAttrs (_: hostConfig: hostConfig.system == system) nixosHosts;
    getHostPkgs = pkgsForHost pkgs pkgs-stable;
  in
    lib.mapAttrs'
    (
      hostname: hostConfig:
        lib.nameValuePair "${hostname}-netboot-installer" (mkNetbootInstaller (getHostPkgs hostConfig) hostname hostConfig)
    )
    systemHosts
    // lib.mapAttrs'
    (
      hostname: hostConfig:
        lib.nameValuePair "${hostname}-iso-contents" (mkIsoContents (getHostPkgs hostConfig) hostname hostConfig)
    )
    systemHosts
    // lib.mapAttrs'
    (
      hostname: hostConfig: let
        hostPkgs =
          if hostConfig.system == system
          then getHostPkgs hostConfig
          else mkHostPkgs hostConfig;
        buildPkgs = pkgsForHost pkgs pkgs-stable hostConfig;
      in
        lib.nameValuePair "${hostname}-iso" (mkLocalIso {inherit buildPkgs hostPkgs;} hostname hostConfig)
    )
    nixosHosts;

  appsForSystem = pkgs:
    lib.mapAttrs'
    (
      hostname: hostConfig:
        lib.nameValuePair "${hostname}-netboot" (mkNetbootApp pkgs hostname hostConfig)
    )
    nixosHosts;
}
