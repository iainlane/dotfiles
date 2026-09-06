# Support for the gitsign signing format. The git configuration itself is
# generated in home-manager.nix; this runs the long-lived credential cache so
# that each signature does not need a fresh OIDC authentication.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.dotfiles.git.signing;

  gitsignConfigs =
    lib.optional (cfg.global ? gitsign) cfg.global
    ++ lib.filter (scfg: scfg ? gitsign) (lib.attrValues cfg.directories);

  connectorIDs = lib.unique (map (scfg: scfg.gitsign.connectorID) gitsignConfigs);

  gitsignCredentialCache = "${config.xdg.cacheHome}/sigstore/gitsign/cache.sock";
in {
  config = lib.mkIf (cfg.gitsign.enable || gitsignConfigs != []) {
    home.sessionVariables =
      {
        GITSIGN_CREDENTIAL_CACHE = gitsignCredentialCache;
      }
      # Each directory tree's git configuration sets its own connector, so
      # set the environment variable only when every tree uses the same one.
      // lib.optionalAttrs (lib.length connectorIDs == 1) {
        GITSIGN_CONNECTOR_ID = lib.head connectorIDs;
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
        Install.WantedBy = ["sockets.target"];
      };
    };
  };
}
