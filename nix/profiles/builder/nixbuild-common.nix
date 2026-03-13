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
  mkMachineLine = system: sshKeyPath:
    lib.concatStringsSep " " [
      builderAlias
      system
      sshKeyPath
      "100"
      "1"
      "benchmark,big-parallel,kvm,nixos-test"
      "-"
      "-"
    ];
in {
  inherit builderAlias hostName;
  binaryCaches = {
    "${builderAlias}" = {
      substituter = "ssh://${builderAlias}";
      publicKeyName = signingKeyName;
      key = signingKey;
    };
  };
  adminMatchBlocks = {
    "nixbuild-admin" = userMatchBlock "~/.ssh/id_ed25519_nixbuild" {
      ControlMaster = "no";
      IPQoS = "le";
      PubkeyAcceptedKeyTypes = "ssh-ed25519";
      RemoteCommand = "shell";
    };
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
  }: let
    remoteStoreKeyPath = "${hostConfig.homeDirectory}/.ssh/id_ed25519_nixbuild_store";
  in {
    sops = {
      defaultSopsFile = inputs.secrets + "/nixbuild.yaml";
      secrets.nixbuild-private-key = {
        key = "nixbuild_private_key";
        mode = "0400";
      };
      secrets.nixbuild-remote-store-private-key = {
        key = "nixbuild_remote_store_private_key";
        path = remoteStoreKeyPath;
        owner = username;
        mode = "0400";
      };
    };

    environment.etc = {
      "ssh/ssh_config.d/100-nixbuild.conf".text = ''
        Host ${builderAlias}
          ControlMaster auto
          ControlPath ~/.ssh/ssh-nixbuild-builder-%C
          ControlPersist 10m
          HostKeyAlias ${hostName}
          HostName ${hostName}
          IPQoS le
          IdentitiesOnly yes
          PubkeyAcceptedKeyTypes ssh-ed25519
          ServerAliveInterval 60
      '';

      "ssh/ssh_known_hosts".text = ''
        ${hostName} ${hostKey}
      '';
    };
  };
}
