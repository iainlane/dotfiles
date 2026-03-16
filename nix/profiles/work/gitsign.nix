{
  config,
  pkgs,
  ...
}: let
  gitsignCredentialCache = "${config.xdg.cacheHome}/sigstore/gitsign/cache.sock";
in {
  home = {
    packages = [pkgs.gitsign];
    sessionVariables = {
      GITSIGN_CONNECTOR_ID = "https://accounts.google.com";
      GITSIGN_CREDENTIAL_CACHE = gitsignCredentialCache;
    };
  };

  systemd.user = {
    services.gitsign-credential-cache = {
      Unit.Description = "GitSign credential cache";
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.gitsign}/bin/gitsign-credential-cache --systemd-socket-activation";
      };
    };

    sockets.gitsign-credential-cache = {
      Unit.Description = "GitSign credential cache socket";
      Socket = {
        ListenStream = gitsignCredentialCache;
        DirectoryMode = "0700";
      };
      Install.WantedBy = ["default.target"];
    };
  };
}
