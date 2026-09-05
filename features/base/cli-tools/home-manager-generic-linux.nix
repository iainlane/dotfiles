{pkgs, ...}: {
  # `-R` tells netdiscover to skip its own root check. The
  # `set-network-capabilities` service in os/generic-linux/system.nix grants
  # netdiscover cap_net_raw and cap_net_admin, so this wrapper is installed
  # only there.
  home.packages = [
    (pkgs.writeShellScriptBin "netdiscover" ''
      exec ${pkgs.netdiscover}/bin/netdiscover -R "$@"
    '')
  ];
}
