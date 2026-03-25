{lib}: let
  builderAlias = "nixbuild-builder";
  hostName = "eu.nixbuild.net";
  hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
  signingKeyName = "nixbuild.net/CGKA3W";
  signingKey = "nL2pa46FhLsOxVxHP+TBmMnUz+cuW6pZEreV/MGVaJ4=";
  userMatchBlock = identityFile: extraOptions: {
    hostname = hostName;
    inherit identityFile;
    identitiesOnly = true;
    serverAliveInterval = 60;
    inherit extraOptions;
  };
  systems = ["x86_64-linux" "aarch64-linux" "armv7l-linux"];
  maxJobs = 100;
  speedFactor = 1;
  supportedFeatures = ["benchmark" "big-parallel" "kvm" "nixos-test"];

  binaryCaches = {
    "${builderAlias}" = {
      substituter = "ssh://${builderAlias}";
      publicKeyName = signingKeyName;
      key = signingKey;
    };
  };

  mkMachineLine = system: sshKeyPath:
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
  sshConfigText = ''
    Host ${builderAlias}
      ControlMaster auto
      ControlPath ~/.ssh/ssh-nixbuild-builder-%C
      ControlPersist 10m
      HostKeyAlias ${hostName}
      HostName ${hostName}
      IdentityFile /run/secrets/nixbuild-private-key
      IdentityFile ~/.ssh/id_ed25519_nixbuild
      IPQoS le
      IdentitiesOnly yes
      PubkeyAcceptedKeyTypes ssh-ed25519
      ServerAliveInterval 60
  '';
in {
  inherit binaryCaches builderAlias hostKey hostName maxJobs speedFactor sshConfigText supportedFeatures systems;
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

  machineLine = mkMachineLine;

  machineLines = systems: sshKeyPath:
    lib.concatMapStringsSep "\n" (system: mkMachineLine system sshKeyPath) systems;

  module = {
    hostConfig,
    inputs,
    username,
    ...
  }: {
    dotfiles.nix.binaryCaches."${builderAlias}" = binaryCaches."${builderAlias}";

    nix.settings = {
      builders-use-substitutes = true;
    };

    sops = {
      defaultSopsFile = inputs.secrets + "/nixbuild.yaml";
      secrets = {
        nixbuild-builder-private-key = {
          key = "nixbuild_private_key";
          owner = username;
          path = "${hostConfig.homeDirectory}/.ssh/id_ed25519_nixbuild";
          mode = "0400";
        };
        nixbuild-private-key = {
          key = "nixbuild_private_key";
          mode = "0400";
        };
        nixbuild-remote-store-private-key = {
          key = "nixbuild_remote_store_private_key";
          path = "${hostConfig.homeDirectory}/.ssh/id_ed25519_nixbuild_store";
          owner = username;
          mode = "0400";
        };
      };
    };

  };
}
