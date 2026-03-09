{lib, pkgs, ...}: {
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
