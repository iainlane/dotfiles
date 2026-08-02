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

      configPath = "/etc/caddy/config.json";
      originPullCaPath = "/etc/caddy/origin-pull-ca.pem";

      # The token reaches Caddy as an environment variable, so the DNS provider
      # names it by reference and the value stays in a mode-restricted file.
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

      proxyTo = upstream: {
        handler = "reverse_proxy";
        upstreams = [{dial = upstream;}];
      };

      # Identity of the signed-in visitor, carried from the sign-in service's
      # answer onto the request that goes on to the service. Each header is
      # dropped first, so one supplied by the visitor cannot survive, and set
      # again only when the answer actually carried it.
      identityHeaders = [
        "X-Auth-Request-User"
        "X-Auth-Request-Email"
        "X-Auth-Request-Preferred-Username"
        "X-Auth-Request-Groups"
      ];

      copyIdentityHeader = header: let
        answered = "{http.reverse_proxy.header.${header}}";
      in [
        {
          handle = [
            {
              handler = "headers";
              request.delete = [header];
            }
          ];
        }

        {
          match = [{not = [{vars.${answered} = [""];}];}];
          handle = [
            {
              handler = "headers";
              request.set.${header} = [answered];
            }
          ];
        }
      ];

      # Asks the sign-in service whether it knows the visitor, before the
      # request reaches the service behind it. One sign-in service serves every
      # protected site, so the identity provider needs only one callback
      # address however many sites there are.
      authGate = {
        handler = "reverse_proxy";
        upstreams = [{dial = authUpstream;}];

        # The question is asked of a fixed path, whatever was originally
        # requested; the original method and path travel as headers.
        rewrite = {
          method = "GET";
          uri = "/oauth2/auth";
        };

        headers.request.set = {
          "X-Forwarded-Method" = ["{http.request.method}"];
          "X-Forwarded-Uri" = ["{http.request.uri}"];
          "X-Real-Ip" = ["{http.vars.client_ip}"];
        };

        handle_response = [
          {
            match.status_code = [2];
            routes = lib.concatMap copyIdentityHeader identityHeaders;
          }

          # An unrecognised visitor is sent to sign in and comes back to where
          # they started.
          {
            match.status_code = [401];
            routes = [
              {
                handle = [
                  {
                    handler = "static_response";
                    status_code = 302;
                    headers.Location = ["https://${cfg.auth.domain}/oauth2/sign_in?rd={http.request.scheme}://{http.request.host}{http.request.uri}"];
                  }
                ];
              }
            ];
          }
        ];
      };

      siteRoute = name: container: let
        inherit (container.containerConfig) labels;
        authenticated = labels."edge-proxy.auth" == "true";
      in {
        match = [{host = [labels."edge-proxy.domain"];}];
        terminal = true;
        handle = [
          {
            handler = "subroute";
            routes =
              lib.optional authenticated {handle = [authGate];}
              ++ [{handle = [(proxyTo "${name}:${labels."edge-proxy.port"}")];}];
          }
        ];
      };

      authSiteRoute = {
        match = [{host = [cfg.auth.domain];}];
        terminal = true;
        handle = [
          {
            handler = "subroute";
            routes = [
              {
                handle = [
                  (lib.recursiveUpdate (proxyTo authUpstream) {
                    headers.request.set."X-Real-Ip" = ["{http.vars.client_ip}"];
                  })
                ];
              }
            ];
          }
        ];
      };

      acmeIssuer = ca:
        {
          module = "acme";
          inherit (cfg) email;
          challenges.dns.provider = {
            name = "cloudflare";
            api_token = "{env.${tokenEnvVar}}";
          };
        }
        // lib.optionalAttrs (ca != null) {inherit ca;};

      # Connections from these addresses are served without being asked for a
      # certificate. Policies are tried in order, so this one has to come first
      # for those addresses to reach the host at all.
      directPolicy = {match.remote_ip.ranges = cfg.originAuth.directSources;};

      originPolicy.client_authentication = {
        mode = "require_and_verify";
        ca = {
          provider = "file";
          pem_files = [originPullCaPath];
        };
      };

      caddyConfig.apps = {
        http.servers.edge =
          {
            listen = [":443"];

            routes =
              lib.optional cfg.auth.enable authSiteRoute
              ++ lib.mapAttrsToList siteRoute exposed;

            # An empty object turns on access logging under the default
            # logger, which the unit collects into the journal. Without it
            # Caddy records errors alone, and a served request leaves no trace.
            logs = {};
          }
          // lib.optionalAttrs cfg.originAuth.enable {
            tls_connection_policies =
              lib.optional (cfg.originAuth.directSources != []) directPolicy
              ++ [originPolicy];

            # Caddy turns this on by itself once a client certificate is asked
            # for, and says so in a warning. Setting it is the same thing said
            # out loud.
            strict_sni_host = true;

            # Which visitor a request came from is taken from the header
            # Cloudflare sets. Every source is believed, because the policies
            # above already decide who may connect: a peer either proved it was
            # Cloudflare or came from `directSources`.
            trusted_proxies = {
              source = "static";
              ranges = ["0.0.0.0/0" "::/0"];
            };
            client_ip_headers = ["Cf-Connecting-Ip"];
          };

        # Let's Encrypt, falling back to ZeroSSL where it will not issue.
        tls.automation.policies = [
          {issuers = [(acmeIssuer null) (acmeIssuer "https://acme.zerossl.com/v2/DV90")];}
        ];
      };

      configFile = pkgs.writeText "caddy-config.json" (builtins.toJSON caddyConfig);
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
              ipRanges =
                [cfg.network.v4.range]
                ++ lib.optional (cfg.network.v6.range != null) cfg.network.v6.range;
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
                  exec = "run --config ${configPath}";
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

                  # The config carries no secrets, so it is mounted from the
                  # store. Naming the store path in the quadlet means a changed
                  # config changes the unit that mounts it.
                  volumes =
                    [
                      "caddy-data:/data"
                      "caddy-config:/config"
                      "${configFile}:${configPath}:ro"
                    ]
                    ++ lib.optional cfg.originAuth.enable "${cfg.originAuth.caFile}:${originPullCaPath}:ro";

                  environmentFiles = [config.sops.templates."caddy.env".path];
                  environments.XDG_DATA_HOME = "/data";
                };

                # A protected site is served by asking the sign-in service
                # about the visitor, so Caddy answers 502 for it whenever that
                # service is absent.
                unitConfig = {
                  Description = "Caddy reverse proxy";
                  After = ["network-online.target" "sops-install-secrets.service"] ++ lib.optional cfg.auth.enable "${cfg.auth.containerName}.service";
                  Wants = ["network-online.target" "sops-install-secrets.service"] ++ lib.optional cfg.auth.enable "${cfg.auth.containerName}.service";
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
