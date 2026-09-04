{
  lib,
  pkgs,
  ...
}: {
  dotfiles.hermes = {
    environment.TERMINAL_LOCAL_PERSISTENT = lib.mkDefault "true";

    agentPackages = with pkgs; [
      curl
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
      wget
      xz
      zip
    ];
  };
}
