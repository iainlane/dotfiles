{
  lib,
  pkgs,
  ...
}: let
  coreutil = lib.getExe' pkgs.coreutils;
in {
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

  # Stage 2 runs this script with only coreutils and util-linux on PATH, so
  # curl and sed have to be referenced by store path. The coreutils commands
  # are referenced the same way so every command in the script resolves to a
  # pinned build.
  boot.postBootCommands = lib.mkAfter ''
    root_ssh_dir=/root/.ssh
    nixos_ssh_dir=/home/nixos/.ssh

    ${coreutil "install"} -d -m 0700 "$root_ssh_dir" "$nixos_ssh_dir"
    ${coreutil "touch"} "$root_ssh_dir/authorized_keys" "$nixos_ssh_dir/authorized_keys"
    ${coreutil "chmod"} 0600 "$root_ssh_dir/authorized_keys" "$nixos_ssh_dir/authorized_keys"
    ${coreutil "chown"} -R nixos:users "$nixos_ssh_dir"

    for o in $(</proc/cmdline); do
      case "$o" in
        live.nixos.authorizedKeysUrl=*)
          url="''${o#live.nixos.authorizedKeysUrl=}"
          ${lib.getExe pkgs.curl} --fail --silent --show-error --location "$url" | ${lib.getExe pkgs.gnused} -e '$a\' | ${coreutil "tee"} -a "$root_ssh_dir/authorized_keys" >> "$nixos_ssh_dir/authorized_keys"
          ;;
      esac
    done
  '';
}
