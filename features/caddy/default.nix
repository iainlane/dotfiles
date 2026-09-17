# Caddy is the single entry point for container services. It resolves each
# and terminates TLS with certificates issued through the ACME DNS-01
# challenge, so a certificate can be issued before any traffic arrives.
#
# Caddy's own network has a public IPv6 range delegated from the prefix routed
# to this host, so Caddy has an IPv6 address the internet routes to directly.
# The host has only one public IPv4 address, so no IPv4 range can be delegated
# the same way, and ports 80 and 443 are published on that address instead.
# The sites to serve come from the containers themselves: anything wrapped in
# `exposePodman` gets labels giving its domain and whether it
# requires signing in first. This feature names no individual service.
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

      # This plugin completes the ACME DNS-01 challenge by writing a TXT record
      # through Cloudflare's API. The certificate authority reads that record
      # from DNS and never connects to this host.
      # renovate: datasource=go depName=github.com/caddy-dns/cloudflare
      cloudflareDnsVersion = "v0.2.4";

      # This plugin matches on the TLS handshake before Caddy hands the
      # connection to the HTTP server, so a service speaking its own protocol
      # can share port 443 with the web sites.
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

      # The Cloudflare API token reaches Caddy in the environment. The
      # generated config refers to it by name, so the token itself stays in the
      # sops template file and out of the store.
      tokenEnvVar = "CF_API_TOKEN";

      authUpstream = "${cfg.auth.containerName}:${toString cfg.auth.port}";

      # oauth2-proxy treats an environment variable named `OAUTH2_PROXY_*` as
      # an option override. Name this one outside that prefix, because it is
      # expanded into the alpha config below instead.
      authClientSecretEnv = "OIDC_CLIENT_SECRET";

      authConfigPath = "/etc/oauth2-proxy.cfg";
      authAlphaConfigPath = "/etc/oauth2-proxy.yaml";

      # Which OIDC claim oauth2-proxy returns under which response header.
      # oauth2-proxy is configured from this set, and Caddy copies the same
      # headers onto the request that it passes to the service, so the header a
      # site's allow-list matches against is written down once.
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

      # oauth2-proxy's alpha config, which is the only place its provider
      # definition and its injected response headers can be given. The rest of
      # the configuration stays in the file below.
      authAlphaConfigFile = (pkgs.formats.yaml {}).generate "oauth2-proxy.yaml" {
        server.bindAddress = "0.0.0.0:${toString cfg.auth.port}";

        providers = [
          {
            id = cfg.auth.clientId;
            provider = "oidc";
            clientID = cfg.auth.clientId;
            # oauth2-proxy expands this when it loads the file, so the secret
            # stays in the environment and out of the store.
            clientSecret = "\${${authClientSecretEnv}}";

            oidcConfig.issuerURL = idp.issuer;

            # PKCE: the token request has to include the verifier for the
            # challenge sent with the authorisation request, so an
            # authorisation code intercepted in flight cannot be redeemed
            # without that verifier.
            code_challenge_method = "S256";

            # No extra parameters on the authorisation request. In particular,
            # no `approval_prompt=force`, which oauth2-proxy's legacy flag
            # configuration sends by default and which makes the provider ask
            # for consent at every sign-in. Every client here has the same
            # operator as the provider, so this configuration does not ask for
            # that additional prompt.
            loginURLParameters = [];
          }
        ];

        injectResponseHeaders = lib.mapAttrsToList authResponseHeader identityClaims;
      };

      # Keys are oauth2-proxy's own option names with underscores for hyphens,
      # pluralised where the option can be given more than once.
      authConfigFile = (pkgs.formats.toml {}).generate "oauth2-proxy.cfg" {
        # A path with no host, so oauth2-proxy builds the callback from the
        # scheme and host of the incoming request. Each protected site
        # therefore has its own callback under its own name.
        redirect_url = "/oauth2/callback";

        cookie_domains = [cfg.auth.cookieDomain];
        cookie_secure = true;

        # Redirect targets oauth2-proxy will accept after sign-in. Without the
        # parent domain listed, a sign-in that started on one subdomain cannot
        # send the visitor on to another.
        whitelist_domains = [cfg.auth.cookieDomain];

        # Caddy terminates TLS, so oauth2-proxy takes the scheme and host for
        # its redirects from the forwarded headers. Only Caddy can set them: it
        # is the only other container on the network oauth2-proxy listens on.
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

      # The containers passed through `exposePodman`, keyed by container name,
      # which is also the name podman resolves them by.
      exposed =
        lib.filterAttrs
        (_: container: (container.containerConfig.labels or {}) ? "edge-proxy.domain")
        config.virtualisation.quadlet.containers;

      authenticated = lib.filterAttrs (_: container: container.containerConfig.labels."edge-proxy.auth" == "true") exposed;

      authenticatedSites = lib.mapAttrsToList (_: container: container.containerConfig.labels."edge-proxy.domain") authenticated;

      # One network per service, with just that service and Caddy on it.
      # oauth2-proxy gets one too, because Caddy asks it about a request before
      # serving that request.
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

      # The identity headers that Caddy copies from oauth2-proxy's response
      # onto the outgoing request. Each header is deleted from the
      # incoming request first, so a visitor cannot supply their own, and set
      # again only when oauth2-proxy's response included it.
      identityHeaders = lib.attrNames identityClaims;

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

        # The check always goes to `/oauth2/auth`, whatever was requested. The
        # original method and URI travel in the headers below.
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

          # A visitor who is not signed in is redirected to sign in, and comes
          # back to the URI they asked for.
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

      # Refuses a signed-in visitor whose username is not in `auth.allow`,
      # reading the header `authGate` has just set from oauth2-proxy's
      # response. The identity provider decides who may sign in at all; this
      # decides which of those accounts reach this host.
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

      # `/oauth2/*` on every protected site goes to oauth2-proxy, so signing in
      # and the callback both happen under the site's own name. The identity
      # provider is given one redirect URI per site.
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
            routes =
              lib.optionals authenticated (
                [signInRoute {handle = [authGate];}]
                ++ lib.optional (cfg.auth.allow != []) allowGate
              )
              ++ [{handle = [(proxyTo "${name}:${labels."edge-proxy.port"}")];}];
          }
        ];
      };

      # A service speaking its own protocol. The ALPN name in the TLS handshake
      # tells Caddy to hand the connection here, so the service shares port 443
      # with the web sites and gets the connection decrypted.
      # These services have no sign-in. The client is identified by its
      # certificate, which Caddy compares in full against the ones in
      # `trustedClients`.
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
                # `require` asks the client for a certificate without checking
                # it against a certificate authority. These certificates are
                # self-signed and have no chain, so the leaf verifier below
                # makes the decision.
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

      # A service calling the identity provider comes from a per-service
      # network and has no Cloudflare certificate to present, so every range
      # podman draws its networks from is exempt as well.
      containerSources = config.dotfiles.containers.subnetPools;

      # Connections from these addresses are served without being asked for a
      # certificate. Caddy tries the policies in order, so this one has to come
      # before `originPolicy`.
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
            # Caddy logs errors only, and a request that was served is not
            # recorded at all.
            logs = {};
          }
          // lib.optionalAttrs (listenerWrappers != []) {
            listener_wrappers = listenerWrappers;
          }
          // lib.optionalAttrs cfg.originAuth.present {
            tls_connection_policies = [directPolicy originPolicy];

            strict_sni_host = true;

            # The client address comes from the header Cloudflare sets. Every
            # source is trusted to set it because the connection policies above
            # already decide who may connect at all: a peer either presented a
            # Cloudflare origin-pull certificate or came from `directSources`
            # or a podman network.
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

        # oauth2-proxy answers under each protected site's own domain and the
        # callback lands on the site where the visitor started, so register a
        # redirect URI for every site behind single sign-on.
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
          # podman allocates the per-service networks itself; nothing on them
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
                # from the store. The quadlet names the store path, so a
                # changed config changes the unit that mounts it.
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

                # Binding ports 80 and 443 is the one privilege Caddy keeps.
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

                # The client secret and the cookie secret arrive in the
                # environment, so neither is written into the store.
                environmentFiles = [config.sops.templates."oauth2-proxy.env".path];

                # oauth2-proxy listens above port 1024, so it needs no
                # capabilities.
                dropCapabilities = ["ALL"];
                noNewPrivileges = true;
              };

              # oauth2-proxy fetches the identity provider's discovery document
              # at startup, and reaches the provider by the public name Caddy
              # answers to, so Caddy has to be running first. Caddy needs
              # nothing from oauth2-proxy in order to start: it answers 502 on
              # a protected site until oauth2-proxy is up.
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
