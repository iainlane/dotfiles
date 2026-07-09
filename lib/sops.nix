# SOPS module helpers: assemble the sops-nix fragments each host needs to
# decrypt secrets. The home fragment points sops at the user age key (and wires
# up the per-host SSH key when the secrets repo carries one); the system
# fragment derives the host age key from the SSH host key.
{
  inputs,
  lib,
}: {
  mkHomeSopsModule = {hostConfig}: let
    sshKeyFile = inputs.secrets + "/${hostConfig.hostname}/user-ssh-key.yaml";
  in
    lib.recursiveUpdate
    {
      sops.age.keyFile = "${hostConfig.homeDirectory}/.config/sops/age/keys.txt";
    }
    (lib.optionalAttrs (builtins.pathExists sshKeyFile) {
      sops.secrets.ssh-private-key = {
        sopsFile = sshKeyFile;
        path = "${hostConfig.homeDirectory}/.ssh/id_ed25519";
      };
    });

  mkSystemSopsModule = {
    sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };
}
