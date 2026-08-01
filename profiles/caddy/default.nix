# Caddy as the single entry point for container services. It sits on a shared
# podman network, resolves each backend by container name, and terminates TLS
# with certificates issued over the ACME DNS-01 challenge, so a certificate can
# be had before any traffic can arrive.
#
# The shared network carries a public IPv6 range delegated from the prefix
# routed to this host, so Caddy holds an address the internet reaches directly.
# IPv4 is a single address that cannot be delegated, so it is published instead.
#
# What to serve is discovered from the containers themselves: anything wrapped
# in `config.lib.edgeProxy.exposePodman` carries labels saying which name it
# answers to and whether it needs signing in first. This profile never names an
# individual service.
{
  flake.profiles.caddy = {
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
      cfg = config.services.caddy-proxy;
      proxy = config.services.edge-proxy;

      inherit (import ../../lib/container-image.nix {inherit pkgs;}) mkNixImage;

      caddyPackage =
        if cfg.package != null
        then cfg.package
        else
          pkgs.caddy.withPlugins {
            plugins = ["github.com/caddy-dns/cloudflare@v0.2.4"];
            hash = "sha256-7GoH8YLCoPmPExQxoga2FHB58zQDoZVf1BBwkVi0SsQ=";
          };

      secretsFile = inputs.secrets + "/${cfg.secretsFile}";
      authSecretsFile = inputs.secrets + "/${cfg.auth.secretsFile}";

      caddyfilePath = "/etc/caddy/Caddyfile";

      # The token reaches Caddy as an environment variable, so `acme_dns` names
      # it by reference and the value stays in a mode-restricted file.
      tokenEnvVar = "CF_API_TOKEN";

      authUpstream = "${cfg.auth.containerName}:${toString cfg.auth.port}";

      caddyImage = mkNixImage cfg.containerName [
        caddyPackage
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.fakeNss
      ];

      authImage = mkNixImage cfg.auth.containerName [
        pkgs.oauth2-proxy
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.fakeNss
      ];

      # Every container the services have offered to the proxy, keyed by
      # container name, which is also the name podman resolves it by.
      exposed =
        lib.filterAttrs
        (_: container: (container.containerConfig.labels or {}) ? "edge-proxy.domain")
        config.virtualisation.quadlet.containers;

      siteBlock = name: container: let
        inherit (container.containerConfig) labels;
        authenticated = labels."edge-proxy.auth" == "true";
      in ''
        ${labels."edge-proxy.domain"} {
        ${lib.optionalString authenticated "  import protected"}
          reverse_proxy ${name}:${labels."edge-proxy.port"}
        }
      '';

      # One sign-in service for every protected site, so the identity provider
      # only ever needs the one callback address. An unauthenticated visitor is
      # sent there and comes back to where they started.
      authSnippet = ''
        (protected) {
          forward_auth ${authUpstream} {
            uri /oauth2/auth

            # forward_auth sets the X-Forwarded-* headers itself, but not
            # X-Real-IP, which oauth2-proxy also expects.
            header_up X-Real-IP {remote_host}

            # Identity of the signed-in visitor, moved from the auth response
            # onto the request that carries on to the service. Only copied when
            # the check succeeded.
            copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Preferred-Username X-Auth-Request-Groups

            @unauthorized status 401
            handle_response @unauthorized {
              redir * https://${cfg.auth.domain}/oauth2/sign_in?rd={scheme}://{host}{uri}
            }
          }
        }

        ${cfg.auth.domain} {
          reverse_proxy ${authUpstream} {
            header_up X-Real-IP {remote_host}
          }
        }
      '';

      caddyfile = ''
        {
          email ${cfg.email}
          acme_dns cloudflare {env.${tokenEnvVar}}
        }

        ${lib.optionalString cfg.auth.enable authSnippet}
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList siteBlock exposed)}
        ${cfg.extraConfig}
      '';
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {services.caddy-proxy = {enable = lib.mkDefault true;} // args;}

        (lib.mkIf cfg.enable {
          services.edge-proxy.enable = true;

          assertions = [
            {
              assertion = cfg.auth.enable || !(lib.any (c: c.containerConfig.labels."edge-proxy.auth" == "true") (lib.attrValues exposed));
              message = "services.caddy-proxy: a site asks to be behind single sign-on, but services.caddy-proxy.auth is not enabled, so it would be served to anyone.";
            }
            {
              assertion = cfg.ipv6Address == null || cfg.network.v6.subnet != null;
              message = "services.caddy-proxy: an IPv6 address is set for the proxy without a subnet for the network to carry it.";
            }
          ];

          sops = {
            secrets =
              {
                ${cfg.dnsTokenKey}.sopsFile = secretsFile;
              }
              // lib.optionalAttrs cfg.auth.enable {
                ${cfg.auth.clientIdKey}.sopsFile = authSecretsFile;
                ${cfg.auth.clientSecretKey}.sopsFile = authSecretsFile;
                ${cfg.auth.cookieSecretKey}.sopsFile = authSecretsFile;
              };

            templates =
              {
                "caddy.env".content = ''
                  ${tokenEnvVar}=${config.sops.placeholder.${cfg.dnsTokenKey}}
                '';

                # The Caddyfile carries no secrets of its own, but is rendered
                # here alongside them so the proxy has a single config source.
                "Caddyfile".content = caddyfile;
              }
              // lib.optionalAttrs cfg.auth.enable {
                "oauth2-proxy.env".content = ''
                  OAUTH2_PROXY_CLIENT_ID=${config.sops.placeholder.${cfg.auth.clientIdKey}}
                  OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder.${cfg.auth.clientSecretKey}}
                  OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.${cfg.auth.cookieSecretKey}}
                '';
              };
          };

          virtualisation.quadlet = {
            networks.${proxy.network}.networkConfig = {
              subnets =
                [cfg.network.v4.subnet]
                ++ lib.optional (cfg.network.v6.subnet != null) cfg.network.v6.subnet;
              gateways =
                [cfg.network.v4.gateway]
                ++ lib.optional (cfg.network.v6.gateway != null) cfg.network.v6.gateway;
              ipv6 = cfg.network.v6.subnet != null;
            };

            # `optionalAttrs` rather than `mkIf`: an attribute defined as
            # `mkIf false` still exists, leaving quadlet-nix to render an
            # object with nothing set.
            images =
              {
                ${cfg.containerName}.imageConfig = {
                  image = "docker-archive:${caddyImage}";
                  tag = "localhost/${cfg.containerName}:${caddyImage.imageTag}";
                };
              }
              // lib.optionalAttrs cfg.auth.enable {
                ${cfg.auth.containerName}.imageConfig = {
                  image = "docker-archive:${authImage}";
                  tag = "localhost/${cfg.auth.containerName}:${authImage.imageTag}";
                };
              };

            containers = {
              ${cfg.containerName} = {
                containerConfig = {
                  image = config.virtualisation.quadlet.images.${cfg.containerName}.ref;
                  networks = ["${proxy.network}.network"];
                  ip6 = cfg.ipv6Address;
                  exec = "run --config ${caddyfilePath} --adapter caddyfile";
                  entrypoint = "${caddyPackage}/bin/caddy";

                  # IPv6 reaches the address above directly. IPv4 is a single
                  # address on the host, which cannot be a network of its own,
                  # so it is published. UDP carries HTTP/3, which Caddy
                  # advertises through Alt-Svc.
                  publishPorts = lib.optionals (cfg.ipv4Address != null) [
                    "${cfg.ipv4Address}:80:80"
                    "${cfg.ipv4Address}:443:443"
                    "${cfg.ipv4Address}:443:443/udp"
                  ];

                  volumes = [
                    "caddy-data:/data"
                    "caddy-config:/config"
                    "${config.sops.templates."Caddyfile".path}:${caddyfilePath}:ro"
                  ];

                  environmentFiles = [config.sops.templates."caddy.env".path];
                  environments.XDG_DATA_HOME = "/data";
                };

                unitConfig = {
                  Description = "Caddy reverse proxy";
                  After = ["network-online.target" "sops-install-secrets.service"];
                  Wants = ["network-online.target" "sops-install-secrets.service"];
                };
              };

              ${cfg.auth.containerName} = lib.mkIf cfg.auth.enable {
                containerConfig = {
                  image = config.virtualisation.quadlet.images.${cfg.auth.containerName}.ref;
                  networks = ["${proxy.network}.network"];
                  entrypoint = "${pkgs.oauth2-proxy}/bin/oauth2-proxy";
                  environmentFiles = [config.sops.templates."oauth2-proxy.env".path];

                  environments =
                    {
                      OAUTH2_PROXY_PROVIDER = "github";
                      OAUTH2_PROXY_HTTP_ADDRESS = "0.0.0.0:${toString cfg.auth.port}";
                      OAUTH2_PROXY_REDIRECT_URL = "https://${cfg.auth.domain}/oauth2/callback";
                      OAUTH2_PROXY_COOKIE_DOMAINS = cfg.auth.cookieDomain;
                      # What lets the redirect after sign-in land on a
                      # different subdomain from the one that authenticated.
                      OAUTH2_PROXY_WHITELIST_DOMAINS = cfg.auth.cookieDomain;
                      OAUTH2_PROXY_COOKIE_SECURE = "true";
                      # Caddy terminates TLS, so the scheme and host used to
                      # build redirects come from the forwarded headers.
                      OAUTH2_PROXY_REVERSE_PROXY = "true";
                      # Asked only whether a request is authenticated, over
                      # /oauth2/auth, so it never proxies to a service itself
                      # and needs no upstream.
                      OAUTH2_PROXY_SET_XAUTHREQUEST = "true";
                      # Accounts are allowed by GitHub identity, which the
                      # provider docs pair with accepting any email domain.
                      OAUTH2_PROXY_EMAIL_DOMAINS = "*";
                      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON = "true";
                    }
                    // lib.optionalAttrs (cfg.auth.githubUsers != []) {
                      OAUTH2_PROXY_GITHUB_USERS = lib.concatStringsSep "," cfg.auth.githubUsers;
                    };
                };

                unitConfig = {
                  Description = "Single sign-on for the sites Caddy protects";
                  After = ["network-online.target" "sops-install-secrets.service"];
                  Wants = ["network-online.target" "sops-install-secrets.service"];
                };
              };
            };

            volumes = {
              caddy-data = {};
              caddy-config = {};
            };
          };
        })
      ];
    };
  };
}
