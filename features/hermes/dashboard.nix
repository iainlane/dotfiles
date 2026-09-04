# The Hermes web dashboard: the same image and binary as the gateway, run with
# the `dashboard` sub-command in its own container.
#
# Hermes makes anyone reaching a non-loopback bind sign in. It uses the same
# identity provider as the proxy, so one sign-in covers both. It has no list of
# who may get in, and serves anyone the provider recognises, so the proxy's
# `allow` list is what limits that.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
  inherit (cfg) dashboard;

  idp = config.services.identity-provider;

  exposed = dashboard.expose != null && config.services.edge-proxy.enable;

  publicUrl = "https://${dashboard.expose.domain}";

  clientId = dashboard.containerName;

  # The proxy has to be able to reach it, so it binds every address. That is
  # also what makes Hermes require a sign-in.
  bindAddress =
    if exposed
    then "0.0.0.0"
    else dashboard.address;

  inherit (import ./builders.nix {inherit config inputs lib pkgs;}) mkHermesContainer;

  dashboardContainer = mkHermesContainer {
    description = "Hermes Agent Web Dashboard";

    exec = lib.concatStringsSep " " [
      "dashboard"
      "--host"
      bindAddress
      "--port"
      (toString dashboard.port)
      "--no-open"
      "--skip-build"
    ];

    networks =
      lib.toList cfg.container.network
      ++ lib.optional cfg.signal.enable "${cfg.signal.network}.network";

    environments = lib.optionalAttrs exposed {
      # Where someone is sent back to after signing in. The request reaches
      # Hermes from the proxy and does not carry the name it was asked for,
      # so Hermes is told it here.
      HERMES_DASHBOARD_PUBLIC_URL = publicUrl;
      HERMES_DASHBOARD_OIDC_ISSUER = idp.issuer;
      HERMES_DASHBOARD_OIDC_CLIENT_ID = clientId;
    };

    environmentFiles = lib.optional exposed config.sops.templates."hermes-dashboard.env".path;

    after =
      ["${cfg.container.name}.service"]
      # It reaches the provider by the name the proxy answers to.
      ++ lib.optional exposed "${config.services.caddy-proxy.containerName}.service";
  };
in {
  config = lib.mkIf (cfg.enable && dashboard.enable) (lib.mkMerge [
    {
      virtualisation.quadlet.containers.${dashboard.containerName} =
        if exposed
        then config.services.edge-proxy.exposePodman dashboard.containerName dashboardContainer (dashboard.expose // {inherit (dashboard) port;})
        else dashboardContainer;
    }

    (lib.mkIf exposed {
      assertions = [
        {
          assertion = dashboard.secretsFile != null;
          message = ''
            services.hermes-agent.dashboard is exposed, so it signs people in
            and needs `dashboard.secretsFile` for the secret it shares with
            the identity provider.
          '';
        }
      ];

      services.identity-provider.clients.${clientId} = {
        displayName = "Hermes";
        redirectURIs = ["${publicUrl}/auth/callback"];
        inherit (dashboard) secretsFile;
        secretKey = dashboard.clientSecretKey;
      };

      sops = {
        secrets.${dashboard.clientSecretKey}.sopsFile = inputs.secrets + "/${dashboard.secretsFile}";

        templates."hermes-dashboard.env".content = ''
          HERMES_DASHBOARD_OIDC_CLIENT_SECRET=${config.sops.placeholder.${dashboard.clientSecretKey}}
        '';
      };
    })
  ]);
}
