# Caddy is the single entry point for a host's container services. It resolves
# each backend by container name over a network shared with that service alone,
# and obtains its certificates through the ACME DNS-01 challenge.
#
# The sites to serve come from the containers themselves: a container wrapped
# in `exposePodman` has labels for its domain and for whether a visitor has to
# sign in first. No individual service is configured here.
{config, ...}: let
  inherit (config.flake) features;
  children = features.caddy.provides;
in {
  imports = [./auth ./origin-auth];

  flake.features.caddy = {
    includes = [features.containers] ++ (with children; [auth origin-auth]);

    systemManager = {
      config,
      inputs,
      lib,
      pkgs,
      quadlet,
      serviceNetwork,
      ...
    }: let
      cfg = config.dotfiles.caddy;
      proxy = config.dotfiles.containers.edgeProxy;
      idp = config.dotfiles.containers.identityProvider;

      inherit (import ../../lib/container-image.nix {inherit pkgs;}) mkNixImage;

      # renovate: datasource=go depName=github.com/caddy-dns/cloudflare
      cloudflareDnsVersion = "v0.2.4";

      # Serves `edgeProxy.streams`: this plugin matches a connection on its TLS
      # handshake, before the HTTP server sees it.
      # renovate: datasource=go depName=github.com/mholt/caddy-l4
      caddyL4Version = "v0.1.2";

      caddyPackage =
        if cfg.package != null
        then cfg.package
        else
          pkgs.caddy.withPlugins {
            plugins = [
              "github.com/caddy-dns/cloudflare@${cloudflareDnsVersion}"
              "github.com/mholt/caddy-l4@${caddyL4Version}"
            ];
            hash = "sha256-6HJkIfqacmsEaubClOVjzPM+7Jy5Z7xHVORzf6+5OxU=";
          };

      secretsFile = inputs.secrets + "/${cfg.secretsFile}";
      authSecretsFile = inputs.secrets + "/${cfg.auth.secretsFile}";

      configPath = "/etc/caddy/config.json";
      originPullCaPath = "/etc/caddy/origin-pull-ca.pem";

      # The generated config is world-readable in the store, so it refers to
      # this variable and the token itself stays in the sops template.
      tokenEnvVar = "CF_API_TOKEN";

      authUpstream = "${cfg.auth.containerName}:${toString cfg.auth.port}";

      # oauth2-proxy treats an environment variable named `OAUTH2_PROXY_*` as
      # an option override. Name this one outside that prefix, because it is
      # expanded into the alpha config below instead.
      authClientSecretEnv = "OIDC_CLIENT_SECRET";

      authConfigPath = "/etc/oauth2-proxy.cfg";
      authAlphaConfigPath = "/etc/oauth2-proxy.yaml";

      # The OIDC claim that oauth2-proxy returns under each response header.
      # oauth2-proxy is configured from this set, and Caddy copies the same
      # headers onto the request that it forwards, so a site's allow-list
      # matches a header written down once.
      identityClaims = {
        "X-Auth-Request-User" = "user";
        "X-Auth-Request-Email" = "email";
        "X-Auth-Request-Preferred-Username" = "preferred_username";
        "X-Auth-Request-Groups" = "groups";
      };

      authResponseHeader = header: claim: {
        name = header;
        values = [{claimSource = {inherit claim;};}];
      };

      # The alpha config is the only place where oauth2-proxy accepts a
      # provider definition and injected response headers. Everything else it
      # needs is in `authConfigFile`.
      authAlphaConfigFile = (pkgs.formats.yaml {}).generate "oauth2-proxy.yaml" {
        server.bindAddress = "0.0.0.0:${toString cfg.auth.port}";

        providers = [
          {
            id = cfg.auth.clientId;
            provider = "oidc";
            clientID = cfg.auth.clientId;
            # oauth2-proxy expands this when it reads the file, so the secret
            # stays in the environment.
            clientSecret = "\${${authClientSecretEnv}}";

            oidcConfig.issuerURL = idp.issuer;

            # PKCE: the token request has to include the verifier for the
            # challenge sent with the authorisation request, so an
            # authorisation code intercepted in flight cannot be redeemed
            # without that verifier.
            code_challenge_method = "S256";

            # An empty list is not the same as leaving this out: oauth2-proxy's
            # legacy configuration defaults to `approval_prompt=force`, which
            # asks the provider for consent at every sign-in.
            loginURLParameters = [];
          }
        ];

        injectResponseHeaders = lib.mapAttrsToList authResponseHeader identityClaims;
      };

      # Keys are oauth2-proxy's own option names with hyphens written as
      # underscores, pluralised where the option can be repeated.
      authConfigFile = (pkgs.formats.toml {}).generate "oauth2-proxy.cfg" {
        # A path with no host, so oauth2-proxy builds the callback from the
        # scheme and host of the incoming request. Each protected site
        # therefore has its own callback under its own name.
        redirect_url = "/oauth2/callback";

        cookie_domains = [cfg.auth.cookieDomain];
        cookie_secure = true;

        # oauth2-proxy refuses to redirect anywhere else after sign-in. The
        # parent domain is listed so a sign-in that started on one subdomain
        # can send the visitor on to another.
        whitelist_domains = [cfg.auth.cookieDomain];

        # Caddy terminates TLS, so oauth2-proxy takes the scheme and host of
        # its redirects from the forwarded headers. Caddy is the only other
        # container on the network that oauth2-proxy listens on, so nothing
        # else can set them.
        reverse_proxy = true;
        trusted_proxy_ips = containerSources;

        # `auth.allow` in front of each site decides which accounts are served,
        # so oauth2-proxy accepts any address that the provider returns.
        email_domains = ["*"];

        skip_provider_button = true;
      };

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

      # Every container wrapped in `exposePodman`, keyed by the name that
      # podman resolves it by.
      exposed =
        lib.filterAttrs
        (_: container: (container.containerConfig.labels or {}) ? "edge-proxy.domain")
        config.virtualisation.quadlet.containers;

      authenticated = lib.filterAttrs (_: container: container.containerConfig.labels."edge-proxy.auth" == "true") exposed;

      authenticatedSites = lib.mapAttrsToList (_: container: container.containerConfig.labels."edge-proxy.domain") authenticated;

      # oauth2-proxy gets a network of its own as well, because Caddy asks it
      # about a request before serving that request.
      serviceNetworks =
        map serviceNetwork (lib.attrNames exposed)
        ++ map serviceNetwork (lib.attrNames proxy.streams)
        ++ lib.optional cfg.auth.present (serviceNetwork cfg.auth.containerName);

      # A client of the identity provider fetches the discovery document, the
      # signing keys and the tokens from the provider's public name. Caddy
      # answers to that name on every per-service network, so those requests
      # stay on this host and are served under the certificate for that name.
      issuerAlias =
        lib.optionalString (idp.enable && idp.issuer != null)
        ":alias=${lib.removePrefix "https://" idp.issuer}";

      # podman accepts `--ip6` only for a container on a single network, so the
      # address is given as an option of its own network.
      proxyNetwork =
        "${proxy.network}.network"
        + lib.optionalString (cfg.ipv6Address != null) ":ip6=${cfg.ipv6Address}";

      proxyTo = upstream: {
        handler = "reverse_proxy";
        upstreams = [{dial = upstream;}];
      };

      identityHeaders = lib.attrNames identityClaims;

      # Each identity header is deleted from the incoming request and set again
      # only when oauth2-proxy's response included it, so a visitor cannot send
      # one of these headers themselves.
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

      # Asks oauth2-proxy whether the visitor is signed in, before forwarding
      # the request to the protected service.
      authGate = {
        handler = "reverse_proxy";
        upstreams = [{dial = authUpstream;}];

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

          {
            match.status_code = [401];
            routes = [
              {
                handle = [
                  {
                    handler = "static_response";
                    status_code = 302;
                    headers.Location = ["/oauth2/sign_in?rd={http.request.uri}"];
                  }
                ];
              }
            ];
          }
        ];
      };

      allowGate = {
        match = [{not = [{header."X-Auth-Request-Preferred-Username" = cfg.auth.allow;}];}];
        terminal = true;
        handle = [
          {
            handler = "static_response";
            status_code = 403;
            body = "Signed in, but not on the list for this site.\n";
          }
        ];
      };

      signInRoute = {
        match = [{path = ["/oauth2/*"];}];
        terminal = true;
        handle = [
          (lib.recursiveUpdate (proxyTo authUpstream) {
            headers.request.set."X-Real-Ip" = ["{http.vars.client_ip}"];
          })
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
            # `allowGate` reads a header that `authGate` sets from
            # oauth2-proxy's response, so it has to come after `authGate`.
            routes =
              lib.optionals authenticated (
                [signInRoute {handle = [authGate];}]
                ++ lib.optional (cfg.auth.allow != []) allowGate
              )
              ++ [{handle = [(proxyTo "${name}:${labels."edge-proxy.port"}")];}];
          }
        ];
      };

      streamRoute = name: stream: {
        match = [
          {
            tls = {
              alpn = [stream.alpn];
              sni = [stream.domain];
            };
          }
        ];
        handle = [
          {
            handler = "tls";
            connection_policies = [
              {
                alpn = [stream.alpn];
                # `require` asks for a client certificate without checking it
                # against a certificate authority. These certificates are
                # self-signed, so `verifiers` makes the decision.
                client_authentication = {
                  mode = "require";
                  verifiers = [
                    {
                      verifier = "leaf";
                      leaf_certs_loaders = [
                        {
                          loader = "pem";
                          certificates = stream.trustedClients;
                        }
                      ];
                    }
                  ];
                };
              }
            ];
          }

          {
            handler = "proxy";
            upstreams = [{dial = ["${name}:${toString stream.port}"];}];
          }
        ];
      };

      # Every connection is offered to the stream routes first. The `tls`
      # wrapper after them terminates the connections that they did not match,
      # and the HTTP server serves those.
      listenerWrappers = lib.optionals (proxy.streams != {}) [
        {
          wrapper = "layer4";
          routes = lib.mapAttrsToList streamRoute proxy.streams;
        }
        {wrapper = "tls";}
      ];

      # Caddy obtains a certificate for each hostname in its web
      # routes. A stream has no web route, so its domain is listed here.
      streamDomains = lib.mapAttrsToList (_: stream: stream.domain) proxy.streams;

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

      containerSources = config.dotfiles.containers.subnetPools;

      directPolicy = {match.remote_ip.ranges = cfg.originAuth.directSources ++ containerSources;};

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

            routes = lib.mapAttrsToList siteRoute exposed;

            # An empty object turns on access logging under the default
            # logger, which the unit collects into the journal. Without it
            # Caddy records only errors.
            logs = {};
          }
          // lib.optionalAttrs (listenerWrappers != []) {
            listener_wrappers = listenerWrappers;
          }
          // lib.optionalAttrs cfg.originAuth.present {
            # Caddy tries the policies in order, so `directPolicy` has to come
            # before `originPolicy`.
            tls_connection_policies = [directPolicy originPolicy];

            strict_sni_host = true;

            # Every source is trusted to set the client-address header, because
            # `tls_connection_policies` already decides who may connect: a peer
            # either presented a Cloudflare origin-pull certificate or came
            # from `originAuth.directSources` or a podman network.
            trusted_proxies = {
              source = "static";
              ranges = ["0.0.0.0/0" "::/0"];
            };
            client_ip_headers = ["Cf-Connecting-Ip"];
          };

        # Let's Encrypt, falling back to ZeroSSL if it will not issue.
        tls =
          {
            automation.policies = [
              {issuers = [(acmeIssuer null) (acmeIssuer "https://acme.zerossl.com/v2/DV90")];}
            ];
          }
          // lib.optionalAttrs (streamDomains != []) {
            certificates.automate = streamDomains;
          };
      };

      configFile = (pkgs.formats.json {}).generate "caddy-config.json" caddyConfig;
    in {
      imports = [./options.nix];

      config = {
        dotfiles.containers.edgeProxy = {
          enable = true;
          unit = "${cfg.containerName}.service";
        };

        assertions = [
          {
            assertion = cfg.auth.present || authenticatedSites == [];
            message = ''
              These sites ask to be behind single sign-on: ${lib.concatStringsSep ", " authenticatedSites}.
              The caddy.auth feature is not composed on this host, so they
              would be served to anyone who asks.
            '';
          }
          {
            assertion = !cfg.auth.present || (idp.enable && idp.issuer != null);
            message = ''
              The caddy.auth feature is composed on this host and no feature
              provides an identity provider, so oauth2-proxy would be given a
              null issuer URL and fail at startup. Compose dex, or drop
              caddy.auth and the `auth` setting of every site.
            '';
          }
          {
            assertion = cfg.ipv6Address == null || cfg.network.v6.subnet != null;
            message = "dotfiles.caddy: an IPv6 address is set for the proxy without a subnet for the network to allocate it from.";
          }
          {
            assertion = lib.all (stream: stream.trustedClients != []) (lib.attrValues proxy.streams);
            message = let
              empty = lib.attrNames (lib.filterAttrs (_: stream: stream.trustedClients == []) proxy.streams);
            in ''
              A stream accepts only the clients whose certificates it lists.
              These list none, so every connection to them is refused:
              ${lib.concatStringsSep ", " empty}. Add the certificate of each
              machine that must reach them to `trustedClients`.
            '';
          }
        ];

        dotfiles.containers.identityProvider.clients = lib.mkIf (cfg.auth.present && idp.enable) {
          ${cfg.auth.clientId} = {
            displayName = "Sign in";
            redirectURIs = map (domain: "https://${domain}/oauth2/callback") authenticatedSites;
            inherit (cfg.auth) secretsFile;
            secretKey = cfg.auth.clientSecretKey;
          };
        };

        sops = {
          secrets =
            {
              ${cfg.dnsTokenKey}.sopsFile = secretsFile;
            }
            // lib.optionalAttrs cfg.auth.present {
              ${cfg.auth.clientSecretKey}.sopsFile = authSecretsFile;
              ${cfg.auth.cookieSecretKey}.sopsFile = authSecretsFile;
            };

          templates =
            {
              "caddy.env".content = ''
                ${tokenEnvVar}=${config.sops.placeholder.${cfg.dnsTokenKey}}
              '';
            }
            // lib.optionalAttrs cfg.auth.present {
              "oauth2-proxy.env".content = ''
                ${authClientSecretEnv}=${config.sops.placeholder.${cfg.auth.clientSecretKey}}
                OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.${cfg.auth.cookieSecretKey}}
              '';
            };
        };

        virtualisation.quadlet = {
          networks =
            lib.genAttrs serviceNetworks (_: {})
            // {
              ${proxy.network}.networkConfig = {
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
            };

          images = {
            ${cfg.containerName}.imageConfig = {
              image = "docker-archive:${caddyImage}";
              tag = "localhost/${cfg.containerName}:${caddyImage.imageTag}";
            };

            ${cfg.auth.containerName} = lib.mkIf cfg.auth.present {
              imageConfig = {
                image = "docker-archive:${authImage}";
                tag = "localhost/${cfg.auth.containerName}:${authImage.imageTag}";
              };
            };
          };

          containers = {
            ${cfg.containerName} = {
              containerConfig = {
                image = config.virtualisation.quadlet.images.${cfg.containerName}.ref;
                networks =
                  [proxyNetwork]
                  ++ map (network: "${network}.network${issuerAlias}") serviceNetworks;
                exec = "run --config ${configPath}";
                entrypoint = "${caddyPackage}/bin/caddy";

                # IPv6 traffic is routed to `ipv6Address` on the network
                # directly. The host has one public IPv4 address and no IPv4
                # range to delegate the same way, so these ports are published
                # on that address. The UDP port serves HTTP/3, which Caddy
                # advertises through Alt-Svc.
                publishPorts = lib.optionals (cfg.ipv4Address != null) [
                  "${cfg.ipv4Address}:80:80"
                  "${cfg.ipv4Address}:443:443"
                  "${cfg.ipv4Address}:443:443/udp"
                ];

                # The config contains no secrets, so it is mounted straight
                # from the store. The quadlet refers to the config's store
                # path, so a changed config changes the unit and
                # system-manager restarts Caddy.
                volumes =
                  quadlet.mounts [
                    {
                      source.quadletVolume = "caddy-data";
                      target = "/data";
                    }
                    {
                      source.quadletVolume = "caddy-config";
                      target = "/config";
                    }
                    {
                      source.bind = configFile;
                      target = configPath;
                      readOnly = true;
                    }
                  ]
                  ++ lib.optionals cfg.originAuth.present (quadlet.mounts [
                    {
                      source.bind = cfg.originAuth.caFile;
                      target = originPullCaPath;
                      readOnly = true;
                    }
                  ]);

                environmentFiles = [config.sops.templates."caddy.env".path];
                environments.XDG_DATA_HOME = "/data";

                # Caddy needs NET_BIND_SERVICE for ports 80 and 443, and
                # nothing else.
                dropCapabilities = ["ALL"];
                addCapabilities = ["NET_BIND_SERVICE"];
                noNewPrivileges = true;
              };

              unitConfig = {
                Description = "Caddy reverse proxy";
                After = ["network-online.target" "sops-install-secrets.service"];
                Wants = ["network-online.target" "sops-install-secrets.service"];
              };
            };

            ${cfg.auth.containerName} = lib.mkIf cfg.auth.present {
              containerConfig = {
                image = config.virtualisation.quadlet.images.${cfg.auth.containerName}.ref;
                networks = ["${serviceNetwork cfg.auth.containerName}.network"];
                entrypoint = "${pkgs.oauth2-proxy}/bin/oauth2-proxy";
                exec = "--config ${authConfigPath} --alpha-config ${authAlphaConfigPath}";

                volumes = quadlet.mounts [
                  {
                    source.bind = authConfigFile;
                    target = authConfigPath;
                    readOnly = true;
                  }
                  {
                    source.bind = authAlphaConfigFile;
                    target = authAlphaConfigPath;
                    readOnly = true;
                  }
                ];

                environmentFiles = [config.sops.templates."oauth2-proxy.env".path];

                # oauth2-proxy listens above port 1024, so it needs no
                # capabilities.
                dropCapabilities = ["ALL"];
                noNewPrivileges = true;
              };

              # oauth2-proxy fetches the provider's discovery document at
              # startup, by the public name that Caddy answers to, so Caddy
              # starts first. The dependency does not run the other way: Caddy
              # answers 502 on a protected site until oauth2-proxy is up.
              unitConfig = {
                Description = "Single sign-on for the sites Caddy protects";
                After = ["network-online.target" "sops-install-secrets.service" "${cfg.containerName}.service"];
                Wants = ["network-online.target" "sops-install-secrets.service" "${cfg.containerName}.service"];
              };
            };
          };

          volumes = {
            caddy-data = {};
            caddy-config = {};
          };
        };
      };
    };
  };
}
