{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
in {
  config = lib.mkIf cfg.enable {
    services.hermes-agent = {
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
  };
}
