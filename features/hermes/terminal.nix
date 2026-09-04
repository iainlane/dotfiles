{
  lib,
  pkgs,
  ...
}: {
  dotfiles.hermes = {
    environment.TERMINAL_LOCAL_PERSISTENT = lib.mkDefault "true";

    agentPackages = with pkgs; [
      fd
      gh
      gnutar
      gzip
      jq
      just
      poppler-utils
      rsync
      unzip
      uv
      xz
      zip
    ];
  };
}
