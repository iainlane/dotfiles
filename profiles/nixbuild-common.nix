{lib}: let
  builderAlias = "nixbuild-builder";
  hostName = "eu.nixbuild.net";
  hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
  signingKeyName = "nixbuild.net/CGKA3W";
  signingKey = "nL2pa46FhLsOxVxHP+TBmMnUz+cuW6pZEreV/MGVaJ4=";

  userMatchBlock = identityFile: extraSettings:
    {
      HostName = hostName;
      IdentityFile = identityFile;
      IdentitiesOnly = true;
      ServerAliveInterval = 60;
    }
    // extraSettings;

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

  substituterModule = {
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

  homeManagerModule = {admin ? false}: {
    inputs,
    lib,
    ...
  }:
    lib.mkMerge [
      {
        dotfiles.ssh.settings = storeMatchBlock;
      }
      (lib.mkIf admin {
        sops.secrets.nixbuild-admin-private-key = {
          sopsFile = inputs.secrets + "/nixbuild-admin.yaml";
          key = "nixbuild_admin_public_key";
          path = "~/.ssh/id_ed25519_nixbuild_admin";
        };

        dotfiles.ssh.settings = adminMatchBlock;
      })
    ];

  linuxSystemManagerModule = {
    imports = [substituterModule];

    environment.etc = systemManagerSshConfig;
  };

  nixosModule = {
    imports = [substituterModule];

    programs.ssh = sshProgramConfig;
  };

  darwinSystemManagerModule = {
    imports = [substituterModule];

    system.activationScripts.postActivation.text = ''
      mkdir -p ~/.ssh
      chmod 700 ~/.ssh
    '';

    programs.ssh = sshProgramConfig;
  };

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
in {
  inherit
    adminMatchBlock
    binaryCaches
    builderAlias
    darwinSystemManagerModule
    homeManagerModule
    hostKey
    hostName
    linuxSystemManagerModule
    maxJobs
    nixosModule
    speedFactor
    sshConfigText
    storeMatchBlock
    substituterModule
    supportedFeatures
    systems
    ;

  machineLine = mkMachineLine;

  machineLines = systems: sshKeyPath:
    lib.concatMapStringsSep "\n" (system: mkMachineLine system sshKeyPath) systems;
}
