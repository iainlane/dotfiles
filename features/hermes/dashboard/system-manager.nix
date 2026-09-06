# The Hermes web dashboard: the same image and binary as the gateway, run with
# the `dashboard` sub-command in its own container.
#
# Hermes requires a sign-in from anyone reaching a non-loopback bind. It uses
# the same identity provider as the proxy, so one sign-in covers both. Hermes
# has no list of who may get in and serves anyone the provider recognises, so
# the proxy's `auth.allow` list is what limits access.
{
  config,
  exposePodman,
  hermesBuilders,
  inputs,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
  inherit (cfg) dashboard;

  idp = config.dotfiles.containers.identityProvider;

  proxy = config.dotfiles.containers.edgeProxy;

  exposed = dashboard.expose != null && proxy.enable;

  publicUrl = "https://${dashboard.expose.domain}";

  clientId = dashboard.containerName;

  # When the dashboard is exposed through the proxy it binds every IPv4
  # address, so the proxy can connect to it. Binding a non-loopback address is
  # also what makes Hermes require a sign-in. Otherwise it binds
  # `dashboard.address`.
  bindAddress =
    if exposed
    then "0.0.0.0"
    else dashboard.address;

  inherit (hermesBuilders) mkHermesContainer;

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

    environments = lib.optionalAttrs exposed {
      # Where someone is sent back to after signing in. The request arrives
      # from the proxy without the name the browser used, so Hermes is given
      # that name here.
      HERMES_DASHBOARD_PUBLIC_URL = publicUrl;
      HERMES_DASHBOARD_OIDC_ISSUER = idp.issuer;
      HERMES_DASHBOARD_OIDC_CLIENT_ID = clientId;
    };

    environmentFiles = lib.optional exposed config.sops.templates."hermes-dashboard.env".path;

    after =
      ["${cfg.container.name}.service"]
      # The dashboard reaches the identity provider by the name the proxy
      # answers to.
      ++ lib.optional exposed proxy.unit;
  };
in {
  config = lib.mkMerge [
    {
      dotfiles.hermes.dashboard.present = true;

      assertions = [
        {
          assertion = dashboard.expose == null || dashboard.expose.auth;
          message = ''
            dotfiles.hermes.dashboard.expose.auth is off. Hermes requires a
            sign-in from anyone reaching a non-loopback bind, then serves
            anyone the identity provider recognises, so the proxy's
            `auth.allow` list is what decides who gets in. With `auth` off the
            dashboard is served to every account the provider will
            authenticate.
          '';
        }
      ];

      virtualisation.quadlet.containers.${dashboard.containerName} =
        if exposed
        then exposePodman dashboard.containerName dashboardContainer (dashboard.expose // {inherit (dashboard) port;})
        else dashboardContainer;
    }

    (lib.mkIf exposed {
      dotfiles.containers.identityProvider.clients.${clientId} = {
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
  ];
}
