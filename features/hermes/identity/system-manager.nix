{
  config,
  hermesBuilders,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.hermes;
  inherit (cfg) identity;
  inherit (hermesBuilders) hermesHomeVolume;
  secretsPath = inputs.secrets + "/${identity.secretsFile}";
  available = (import ../../../lib/sops-keys.nix {inherit lib;}).hasKey secretsPath identity.secretKey;
  home = "/home/hermes";
  privateKey = ".ssh/id_ed25519";
  publicKey = "${privateKey}.pub";
  signing = lib.optionalAttrs identity.sign {
    user.signingKey = "${home}/${publicKey}";
    gpg.format = "ssh";
    commit.gpgSign = true;
    tag.gpgSign = true;
  };
  gitconfig = pkgs.writeText "hermes-gitconfig" (lib.generators.toGitINI (
    lib.recursiveUpdate {user = {inherit (identity) name email;};} signing
  ));
  knownHosts = pkgs.writeText "hermes-known-hosts" ''
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
  '';
  secretName = "hermes_ssh_private_key";
in {
  config = lib.mkMerge [
    {dotfiles.hermes.identity.present = true;}
    (lib.mkIf available {
      sops.secrets.${secretName} = {
        sopsFile = secretsPath;
        key = identity.secretKey;
        mode = "0400";
      };
      dotfiles.hermes.container = {
        extraVolumes = [
          {
            source.bind = gitconfig;
            target = "${home}/.gitconfig";
            readOnly = true;
          }
          {
            source.bind = knownHosts;
            target = "/etc/ssh/ssh_known_hosts";
            readOnly = true;
          }
        ];
        extraSetup = ''
          hermes_home_dir="$(podman volume inspect --format '{{.Mountpoint}}' ${hermesHomeVolume})"
          install -d -m 0700 -o "$owner" -g "$owner" "$hermes_home_dir/.ssh"
          install -m 0600 -o "$owner" -g "$owner" \
            "${config.sops.secrets.${secretName}.path}" "$hermes_home_dir/${privateKey}"
          ${pkgs.openssh}/bin/ssh-keygen -y -f "$hermes_home_dir/${privateKey}" > "$hermes_home_dir/${publicKey}"
          chmod 0644 "$hermes_home_dir/${publicKey}"
          chown "$owner:$owner" "$hermes_home_dir/${publicKey}"
        '';
      };
    })
  ];
}
