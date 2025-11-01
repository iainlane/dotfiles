# Run a Linux builder VM so nix can build aarch64-linux derivations on Darwin.
# This replicates the essential parts of nix-darwin's nix.linux-builder module
# without requiring nix.enable (which conflicts with Determinate Nix).
{
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  workingDirectory = "/var/lib/linux-builder";
  linuxBuilderConfig = hostConfig.linuxBuilder or {};
  builderCores = linuxBuilderConfig.cores or 4;
  builderMaxJobs = linuxBuilderConfig.maxJobs or builderCores;
  builderMemoryMiB = linuxBuilderConfig.memoryMiB or 3072;
  linuxBuilder = pkgs.darwin.linux-builder.override {
    modules = [
      {
        virtualisation.cores = builderCores;
        virtualisation.darwin-builder.memorySize = builderMemoryMiB;
      }
    ];
  };
in {
  system.activationScripts.preActivation.text = ''
    mkdir -p ${workingDirectory}
  '';

  launchd.daemons.linux-builder = {
    environment = {
      NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };

    # create-builder uses TMPDIR to share files with the VM, notably certs.
    # macOS cleans /tmp files not accessed for 3+ days during sleep, so use a
    # custom directory that we manage ourselves.
    script = ''
      export TMPDIR=/run/org.nixos.linux-builder USE_TMPDIR=1
      rm -rf $TMPDIR
      mkdir -p $TMPDIR
      trap "rm -rf $TMPDIR" EXIT
      ${linuxBuilder}/bin/create-builder
    '';

    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
      WorkingDirectory = workingDirectory;
    };
  };

  environment.etc = {
    # Determinate Nix reads builders = @/etc/nix/machines by default.
    "nix/machines".text = lib.concatStringsSep " " [
      "ssh-ng://builder@linux-builder" # URI
      "aarch64-linux,x86_64-linux" # systems
      "/etc/nix/builder_ed25519" # SSH key
      (toString builderMaxJobs) # maxJobs
      "1" # speedFactor
      "kvm,benchmark,big-parallel" # supportedFeatures
      "-" # mandatoryFeatures
      "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUpCV2N4Yi9CbGFxdDFhdU90RStGOFFVV3JVb3RpQzVxQkorVXVFV2RWQ2Igcm9vdEBuaXhvcwo=" # publicHostKey
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
}
