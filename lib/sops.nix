# SOPS module helpers: assemble the sops-nix fragments that each host needs in
# order to decrypt secrets. The home fragment points sops at the user age key
# and, when the secrets repository has one, at the per-host SSH key; the system
# fragment derives the host age key from the SSH host key.
#
# One policy covers a per-host secrets file that the secrets input does not
# have: skip the secret's declaration, and let the machine come up without that
# secret. `scripts/generate-user-secrets.bash` writes a machine's user secrets
# in a single run, so a machine that has not been through it has none of them.
# Refusing to evaluate such a machine would leave no way to build the machine
# that run is meant to prepare. os/nixos/system.nix applies the same policy to
# the login password.
{
  inputs,
  lib,
}: {
  mkHomeSopsModule = {hostConfig}: let
    sshKeyFile = inputs.secrets + "/${hostConfig.name}/user-ssh-key.yaml";
  in {
    sops.age.keyFile = "${hostConfig.homeDirectory}/.config/sops/age/keys.txt";

    imports = lib.optional (builtins.pathExists sshKeyFile) {
      sops.secrets.ssh-private-key = {
        sopsFile = sshKeyFile;
        path = "${hostConfig.homeDirectory}/.ssh/id_ed25519";
      };
    };
  };

  systemSopsModule = {
    sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };

  # Containers mount rendered secrets with idmap, which needs tmpfs.
  linuxSystemSopsModule = {
    sops.useTmpfs = true;
  };
}
