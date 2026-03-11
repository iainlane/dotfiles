{lib}: let
  hostName = "eu.nixbuild.net";
  hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
in {
  inherit hostName;

  machineLine = sshKeyPath:
    lib.concatStringsSep " " [
      hostName
      "x86_64-linux"
      sshKeyPath
      "100"
      "1"
      "benchmark,big-parallel"
      "-"
      "-"
    ];

  module = {
    hostConfig,
    inputs,
    ...
  }: {
    sops = {
      age.sshKeyPaths = ["${hostConfig.homeDirectory}/.ssh/age-sops"];
      defaultSopsFile = inputs.secrets + "/nixbuild.yaml";
      secrets.nixbuild-private-key = {
        key = "nixbuild_private_key";
        mode = "0400";
      };
    };

    environment.etc = {
      "ssh/ssh_config.d/100-nixbuild.conf".text = ''
        Host ${hostName}
          PubkeyAcceptedKeyTypes ssh-ed25519
          ServerAliveInterval 60
          IPQoS throughput
      '';

      "ssh/ssh_known_hosts".text = ''
        ${hostName} ${hostKey}
      '';
    };
  };
}
