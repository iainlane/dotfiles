# Run a Linux builder VM so nix can build Linux derivations on Darwin. This
# replicates the essential parts of nix-darwin's nix.linux-builder module
# without requiring nix.enable (which conflicts with Determinate Nix).
#
# QEMU binfmt emulation lets a single aarch64-linux VM also build
# x86_64-linux derivations. Memory and CPU overrides are passed via
# QEMU_OPTS to avoid changing the VM image for those settings.
#
# Bootstrapping: binfmt adds aarch64-linux derivations (QEMU) to the VM
# image, so a working aarch64-linux builder is needed to rebuild. If
# starting from scratch, first deploy with `systems` set to only the
# native architecture, switch, then add x86_64-linux and switch again.
{
  flake.profiles.builder.os.darwin.systemManagerModule = {
    lib,
    pkgs,
    pkgs-stable,
    hostConfig,
    ...
  }: let
    linuxBuilderConfig = hostConfig.linuxBuilder or {};
    workingDirectory = linuxBuilderConfig.workingDirectory or "/var/lib/linux-builder";
    builderCores = linuxBuilderConfig.cores or 4;
    builderMaxJobs = linuxBuilderConfig.maxJobs or builderCores;
    builderMemoryMiB = linuxBuilderConfig.memoryMiB or 3072;
    supportedSystems =
      linuxBuilderConfig.systems
      or [lib.replaceStrings ["darwin"] ["linux"] pkgs.stdenv.hostPlatform.system];
    nativeSystem = lib.replaceStrings ["darwin"] ["linux"] pkgs.stdenv.hostPlatform.system;
    emulatedSystems = builtins.filter (s: s != nativeSystem) supportedSystems;
    linuxBuilder = pkgs-stable.darwin.linux-builder.override {
      modules = [
        {
          boot.binfmt.emulatedSystems = emulatedSystems;
        }
      ];
    };
  in {
    system.activationScripts.preActivation.text = ''
      mkdir -p ${workingDirectory}
    '';

    launchd.daemons.linux-builder = {
      # QEMU_OPTS overrides memory and CPU allocation at launch time so we
      # can keep the builder package identical to the cached default.
      script = ''
        mkdir -p ${workingDirectory}
        export NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        export NIX_DISK_IMAGE=${workingDirectory}/nixos.qcow2
        export QEMU_OPTS="-m ${toString builderMemoryMiB} -smp ${toString builderCores}"
        ${linuxBuilder}/bin/create-builder
      '';

      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        WorkingDirectory = "/";
      };
    };

    environment.etc = {
      # Determinate Nix reads builders = @/etc/nix/machines by default.
      "nix/machines".text = lib.concatStringsSep " " [
        "ssh-ng://builder@linux-builder"
        (lib.concatStringsSep "," supportedSystems)
        "/etc/nix/builder_ed25519"
        (toString builderMaxJobs)
        "1"
        "kvm,benchmark,big-parallel"
        "-"
        "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUpCV2N4Yi9CbGFxdDFhdU90RStGOFFVV3JVb3RpQzVxQkorVXVFV2RWQ2Igcm9vdEBuaXhvcwo="
      ];

      "ssh/ssh_config.d/100-linux-builder.conf".text = ''
        Host linux-builder
          User builder
          Hostname localhost
          HostKeyAlias linux-builder
          Port 31022
          IdentityFile /etc/nix/builder_ed25519
      '';
    };
  };
}
