# The constants that describe the nixbuild.net account: its host, its keys,
# the systems it builds for, and the `/etc/nix/machines` lines that register
# it as a remote builder.
#
# `flake/parts/nix.nix` writes CI's substituter and builder settings from
# these, and `features/nixbuild/` configures the hosts from them, so both read
# them from here.
{lib}: rec {
  builderAlias = "nixbuild-builder";
  hostName = "eu.nixbuild.net";
  hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
  signingKeyName = "nixbuild.net/CGKA3W";
  signingKey = "nL2pa46FhLsOxVxHP+TBmMnUz+cuW6pZEreV/MGVaJ4=";

  systems = ["x86_64-linux" "aarch64-linux" "armv7l-linux"];
  maxJobs = 100;
  speedFactor = 1;
  supportedFeatures = ["benchmark" "big-parallel" "kvm" "nixos-test"];

  binaryCaches = {
    "${builderAlias}" = {
      # The HTTP caches advertise priority 40-41 and the SSH store defaults to
      # 0, which would make nixbuild.net the first substituter consulted for
      # every path. Deprioritise it so it is only a fallback for paths built on
      # nixbuild.net that never reached cupboard.supply.
      substituter = "ssh://${builderAlias}?priority=100";
      publicKeys = ["${signingKeyName}-1:${signingKey}"];
    };
  };

  machineLine = system: sshKeyPath:
    lib.concatStringsSep " " [
      builderAlias
      system
      sshKeyPath
      (toString maxJobs)
      (toString speedFactor)
      (lib.concatStringsSep "," supportedFeatures)
      "-"
      "-"
    ];

  machineLines = systems': sshKeyPath:
    lib.concatMapStringsSep "\n" (system: machineLine system sshKeyPath) systems';

  sshConfigText = ''
    Host ${builderAlias}
      ControlMaster no
      HostKeyAlias ${hostName}
      HostName ${hostName}
      IdentityFile /run/secrets/nixbuild-private-key
      IdentityFile ~/.ssh/id_ed25519_nixbuild
      IPQoS le
      IdentitiesOnly yes
      PubkeyAcceptedKeyTypes ssh-ed25519
      ServerAliveInterval 60
  '';

  sshKnownHost = "${hostName} ${hostKey}";

  sshProgramConfig = {
    extraConfig = sshConfigText;
    knownHosts.nixbuild = {
      hostNames = [hostName];
      publicKey = hostKey;
    };
  };

  systemManagerSshConfig = {
    "ssh/ssh_config.d/100-nixbuild.conf".text = sshConfigText;
    "ssh/ssh_known_hosts".text = sshKnownHost;
  };

  # The user's own SSH aliases for the account: the remote store, and the
  # admin shell for the hosts that manage the account.
  userMatchBlock = identityFile: extraSettings:
    {
      HostName = hostName;
      IdentityFile = identityFile;
      IdentitiesOnly = true;
      ServerAliveInterval = 60;
    }
    // extraSettings;

  adminMatchBlock = {
    "nixbuild-admin" = userMatchBlock "~/.ssh/id_ed25519_nixbuild_admin" {
      ControlMaster = "no";
      IPQoS = "le";
      PubkeyAcceptedKeyTypes = "ssh-ed25519";
      RemoteCommand = "shell";
    };
  };

  storeMatchBlock = {
    "nixbuild-store" = userMatchBlock "~/.ssh/id_ed25519_nixbuild_store" {
      ControlMaster = "auto";
      ControlPath = "~/.ssh/ssh-nixbuild-store-%C";
      ControlPersist = "10m";
      IPQoS = "le";
      PubkeyAcceptedKeyTypes = "ssh-ed25519";
    };
  };
}
