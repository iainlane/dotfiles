# Dex as the host's identity provider: one place that says who someone is, for
# every service that needs to know.
#
# Dex does not hold accounts of its own here. It hands the question to GitHub
# and returns the answer as OpenID Connect, which is a language more things
# speak than GitHub's own API. Whether a given person is served is decided by
# the proxy, from the identity in the answer.
{
  flake.profiles.dex = {
    requires = [
      {
        profile = "containers";
        os = ["linux"];
      }
    ];

    os.linux.systemManagerModule = args: {
      config,
      inputs,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.dex;

      idp = config.services.identity-provider;

      secretsFile = inputs.secrets + "/${cfg.secretsFile}";

      package =
        if cfg.package != null
        then cfg.package
        else pkgs.dex-oidc;

      dataPath = "/var/lib/dex";
      configPath = "/etc/dex/config.yaml";
      stateVolume = "dex-state";

      issuer = "https://${cfg.expose.domain}";

      inherit (import ../../lib/container-image.nix {inherit pkgs;}) mkNixImage;

      image = mkNixImage cfg.containerName [
        package
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.fakeNss
      ];

      githubIdEnv = "DEX_GITHUB_CLIENT_ID";
      githubSecretEnv = "DEX_GITHUB_CLIENT_SECRET";

      clientSecretEnv = name: "DEX_CLIENT_SECRET_${lib.toUpper (builtins.replaceStrings ["-"] ["_"] name)}";

      # A client's secret belongs to the application, so it is read from that
      # application's own sops file.
      clientSecretName = name: "dex_client_secret_${builtins.replaceStrings ["-"] ["_"] name}";

      # Dex expands `$NAME` in a connector's config and reads a client's
      # secret from the variable `secretEnv` names, so every credential
      # arrives in the environment and this file holds none.
      configFile = (pkgs.formats.yaml {}).generate "dex.yaml" (
        {
          inherit issuer;

          storage = {
            type = "sqlite3";
            config.file = "${dataPath}/dex.db";
          };

          web.http = "0.0.0.0:${toString cfg.port}";

          connectors = [
            {
              type = "github";
              id = "github";
              name = "GitHub";
              config =
                {
                  clientID = "$" + githubIdEnv;
                  clientSecret = "$" + githubSecretEnv;
                  redirectURI = "${issuer}/callback";
                }
                // lib.optionalAttrs (cfg.github.orgs != []) {
                  orgs = map (name: {inherit name;}) cfg.github.orgs;
                };
            }
          ];

          staticClients =
            lib.mapAttrsToList (name: client: {
              id = name;
              name = client.displayName;
              secretEnv = clientSecretEnv name;
              inherit (client) redirectURIs;
            })
            idp.clients;

          # Consent is for letting someone hand a third party access to their
          # account elsewhere. Every client here belongs to the same operator
          # as the provider, so there is nothing to hand over.
          oauth2.skipApprovalScreen = true;
        }
        // cfg.settings
      );

      dexContainer = {
        autoStart = true;

        containerConfig = {
          image = config.virtualisation.quadlet.images.${cfg.containerName}.ref;

          userns = "auto";

          entrypoint = "${package}/bin/dex";
          exec = "serve ${configPath}";

          volumes = [
            "${stateVolume}.volume:${dataPath}"
            "${configFile}:${configPath}:ro"
          ];

          environmentFiles = [config.sops.templates."dex.env".path];

          dropCapabilities = ["ALL"];
          noNewPrivileges = true;
        };

        unitConfig = {
          Description = "Dex identity provider";
          After = ["network-online.target" "sops-install-secrets.service"];
          Wants = ["network-online.target" "sops-install-secrets.service"];
        };
      };

      expose = config.services.edge-proxy.enable;
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {services.dex = args;}
        {
          services.identity-provider = {
            enable = true;
            inherit issuer;
          };

          assertions = [
            {
              assertion = !cfg.expose.auth;
              message = ''
                services.dex.expose.auth is on, so signing in would be gated
                behind signing in.
              '';
            }
          ];

          sops = {
            secrets =
              {
                ${cfg.github.clientIdKey}.sopsFile = secretsFile;
                ${cfg.github.clientSecretKey}.sopsFile = secretsFile;
              }
              // lib.mapAttrs' (
                name: client:
                  lib.nameValuePair (clientSecretName name) {
                    sopsFile = inputs.secrets + "/${client.secretsFile}";
                    key = client.secretKey;
                  }
              )
              idp.clients;

            templates."dex.env".content =
              ''
                ${githubIdEnv}=${config.sops.placeholder.${cfg.github.clientIdKey}}
                ${githubSecretEnv}=${config.sops.placeholder.${cfg.github.clientSecretKey}}
              ''
              + lib.concatStrings (
                lib.mapAttrsToList
                (name: _: "${clientSecretEnv name}=${config.sops.placeholder.${clientSecretName name}}\n")
                idp.clients
              );
          };

          virtualisation.quadlet = {
            volumes.${stateVolume} = {};

            images.${cfg.containerName}.imageConfig = {
              image = "docker-archive:${image}";
              tag = "localhost/${cfg.containerName}:${image.imageTag}";
            };

            containers.${cfg.containerName} =
              if expose
              then config.services.edge-proxy.exposePodman cfg.containerName dexContainer (cfg.expose // {inherit (cfg) port;})
              else dexContainer;
          };
        }
      ];
    };
  };
}
