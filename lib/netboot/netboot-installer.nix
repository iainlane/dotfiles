{
  lib,
  pkgs,
  ...
}: {
  # `system.installer.channel.enable` bundles the nixpkgs channel by running
  # `lib.cleanSource pkgs.path`, whose per-file filter walk over the whole
  # nixpkgs tree dominates evaluation of the installer and ISO. `pkgs.path` is
  # already a realised, normalised store path, so the registry references it
  # directly to keep nixpkgs available on the image.
  system.installer.channel.enable = false;
  nix.registry.nixpkgs.to = {
    type = "path";
    inherit (pkgs) path;
  };

  # The installer images enable ZFS support, which warns unless
  # `forceImportRoot` is set explicitly. These images never force-import a
  # root pool, matching the host configurations.
  boot.zfs.forceImportRoot = false;

  boot.postBootCommands = lib.mkAfter ''
    root_ssh_dir=/root/.ssh
    nixos_ssh_dir=/home/nixos/.ssh

    install -d -m 0700 "$root_ssh_dir" "$nixos_ssh_dir"
    touch "$root_ssh_dir/authorized_keys" "$nixos_ssh_dir/authorized_keys"
    chmod 0600 "$root_ssh_dir/authorized_keys" "$nixos_ssh_dir/authorized_keys"
    chown -R nixos:users "$nixos_ssh_dir"

    for o in $(</proc/cmdline); do
      case "$o" in
        live.nixos.authorizedKeysUrl=*)
          url="''${o#live.nixos.authorizedKeysUrl=}"
          ${pkgs.curl}/bin/curl --fail --silent --show-error --location "$url" | ${pkgs.gnused}/bin/sed -e '$a\' | ${pkgs.coreutils}/bin/tee -a "$root_ssh_dir/authorized_keys" >> "$nixos_ssh_dir/authorized_keys"
          ;;
      esac
    done
  '';
}
