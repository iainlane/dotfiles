{
  lib,
  pkgs,
  ...
}:
lib.mkIf pkgs.stdenv.isLinux {
  # netdiscover wrapper that automatically passes -R flag to skip root check.
  # The -R flag tells netdiscover to assume it has the required capabilities.
  # Capabilities are set by systemd service in os/linux/default.nix
  home.packages = [
    (pkgs.writeShellScriptBin "netdiscover" ''
      exec ${pkgs.netdiscover}/bin/netdiscover -R "$@"
    '')
  ];
}
