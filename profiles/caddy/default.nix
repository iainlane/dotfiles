# Caddy as the single entry point for container services. It resolves each
# backend by container name over a network it shares with that service alone,
# and terminates TLS with certificates issued over the ACME DNS-01 challenge,
# so a certificate can be had before any traffic can arrive.
#
# Caddy's own network holds a public IPv6 range delegated from the prefix routed
# to this host, so it has an address the internet reaches directly. IPv4 is a
# single address that cannot be delegated, so it is published instead.
#
# What to serve is discovered from the containers themselves: anything wrapped
# in `config.services.edge-proxy.exposePodman` has labels saying which name it
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
      idp = config.services.identity-provider;

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

      # Named apart from the sign-in service's own OAUTH2_PROXY_ prefix: this
      # one is read by the substitution in the file below, not by the service.
      authClientSecretEnv = "OIDC_CLIENT_SECRET";

      authConfigPath = "/etc/oauth2-proxy.cfg";
      authAlphaConfigPath = "/etc/oauth2-proxy.yaml";

      # The identity of a signed-in visitor, as the sign-in service answers
      # with it. Under the structured configuration these are stated rather
      # than implied, so the header a site's allow-list is matched against is
      # named in the same place it is decided.
      authResponseHeader = header: claim: {
        name = header;
        values = [{claimSource = {inherit claim;};}];
      };

      # The provider and the identity it hands back. Anything the sign-in
      # service accepts more than once, or that describes who it talks to,
      # lives here; what is left in the file below is what this format has no
      # place for yet.
      authAlphaConfigFile = (pkgs.formats.yaml {}).generate "oauth2-proxy.yaml" {
        server.bindAddress = "0.0.0.0:${toString cfg.auth.port}";

        providers = [
          {
            id = cfg.auth.clientId;
            provider = "oidc";
            clientID = cfg.auth.clientId;
            # Substituted when the file is read, so the value stays in the
            # environment and out of the store.
            clientSecret = "\${${authClientSecretEnv}}";

            oidcConfig.issuerURL = idp.issuer;

            # Binds the authorisation code to this exchange, so a code taken
            # in flight cannot be redeemed by anyone else.
            code_challenge_method = "S256";

            # Consent is for letting someone hand a third party access to
            # their account elsewhere. Every client here belongs to the same
            # operator as the provider, so there is nothing to hand over and
            # nothing to ask.
            loginURLParameters = [];
          }
        ];

        injectResponseHeaders = [
          (authResponseHeader "X-Auth-Request-User" "user")
          (authResponseHeader "X-Auth-Request-Email" "email")
          (authResponseHeader "X-Auth-Request-Preferred-Username" "preferred_username")
          (authResponseHeader "X-Auth-Request-Groups" "groups")
        ];
      };

      # Keys are the sign-in service's own option names, with underscores for
      # hyphens and a plural for anything it accepts more than once.
      authConfigFile = (pkgs.formats.toml {}).generate "oauth2-proxy.cfg" {
        # A path with no host: the scheme and host come from the request, so
        # each site's callback is its own, which is what lets the sign-in
        # service live under every site.
        redirect_url = "/oauth2/callback";

        cookie_domains = [cfg.auth.cookieDomain];
        cookie_secure = true;

        # What lets the redirect after sign-in land on a different subdomain
        # from the one that authenticated.
        whitelist_domains = [cfg.auth.cookieDomain];

        # Caddy terminates TLS, so the scheme and host used to build redirects
        # come from the forwarded headers. Only the proxy may set them, and it
        # is the one peer on the network this listens on.
        reverse_proxy = true;
        trusted_proxy_ips = containerSources;

        # Which accounts are served is decided by the allow-list in front of
        # each site, so any address the provider returns is accepted here.
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

      # Every container the services have offered to the proxy, keyed by
      # container name, which is also the name podman resolves it by.
      exposed =
        lib.filterAttrs
        (_: container: (container.containerConfig.labels or {}) ? "edge-proxy.domain")
        config.virtualisation.quadlet.containers;

      # One network per service, with just that service and the proxy on it.
      # The sign-in service gets one too: the proxy asks it about a request
      # before serving it.
      serviceNetworks =
        map proxy.serviceNetwork (lib.attrNames exposed)
        ++ lib.optional cfg.auth.enable (proxy.serviceNetwork cfg.auth.containerName);

      # A client of the identity provider fetches its discovery document, its
      # keys, and the tokens it issues, all from the provider's public name.
      # Answering to that name on the networks it shares with the services
      # keeps those calls on this host, and the certificate they are served
      # under is the one for that name.
      issuerAlias =
        lib.optionalString (idp.enable && idp.issuer != null)
        ":alias=${lib.removePrefix "https://" idp.issuer}";

      # A static address belongs to one network, and podman takes `--ip6` only
      # from a container on a single network, so it is given as an option of
      # the network it is an address on.
      proxyNetwork =
        "${proxy.network}.network"
        + lib.optionalString (cfg.ipv6Address != null) ":ip6=${cfg.ipv6Address}";

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
      # request reaches the service behind it.
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
                    headers.Location = ["/oauth2/sign_in?rd={http.request.uri}"];
                  }
                ];
              }
            ];
          }
        ];
      };

      # Who the sign-in service said the visitor is, once the gate above has
      # set it. The identity provider decides who may sign in at all; this
      # decides which of them this host serves, and does so wherever the
      # identity comes from.
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

      # The sign-in service answers under every site it protects, so signing in
      # happens on the site's own name and its callback is that name too. The
      # identity provider takes a list of them, one per site.
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
      # Podman allocates the per-service networks from this range. A service
      # calling the identity provider comes from one, and holds no certificate
      # from Cloudflare to present; nothing off this host can send from them.
      containerSources = ["10.89.0.0/16"];

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

          # The sign-in service answers under each protected site, so it comes
          # back to whichever one it started at. Every site is listed, and the
          # list follows whatever is exposed.
          services.identity-provider.clients = lib.mkIf (cfg.auth.enable && idp.enable) {
            ${cfg.auth.clientId} = {
              displayName = "Sign in";
              redirectURIs =
                lib.mapAttrsToList
                (_: container: "https://${container.containerConfig.labels."edge-proxy.domain"}/oauth2/callback")
                (lib.filterAttrs (_: container: container.containerConfig.labels."edge-proxy.auth" == "true") exposed);
              inherit (cfg.auth) secretsFile;
              secretKey = cfg.auth.clientSecretKey;
            };
          };

          sops = {
            secrets =
              {
                ${cfg.dnsTokenKey}.sopsFile = secretsFile;
              }
              // lib.optionalAttrs cfg.auth.enable {
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
                  ${authClientSecretEnv}=${config.sops.placeholder.${cfg.auth.clientSecretKey}}
                  OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.${cfg.auth.cookieSecretKey}}
                '';
              };
          };

          virtualisation.quadlet = {
            # Podman allocates the per-service networks itself; nothing on them
            # needs an address anyone has to know in advance.
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
                  networks =
                    [proxyNetwork]
                    ++ map (network: "${network}.network${issuerAlias}") serviceNetworks;
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

                  # Listening below port 1024 is the one privilege it keeps.
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

              ${cfg.auth.containerName} = lib.mkIf cfg.auth.enable {
                containerConfig = {
                  image = config.virtualisation.quadlet.images.${cfg.auth.containerName}.ref;
                  networks = ["${proxy.serviceNetwork cfg.auth.containerName}.network"];
                  entrypoint = "${pkgs.oauth2-proxy}/bin/oauth2-proxy";
                  exec = "--config ${authConfigPath} --alpha-config ${authAlphaConfigPath}";

                  volumes = [
                    "${authConfigFile}:${authConfigPath}:ro"
                    "${authAlphaConfigFile}:${authAlphaConfigPath}:ro"
                  ];

                  # The two secrets arrive as environment, which the sign-in
                  # service reads in preference to its config file, so they
                  # stay out of the store.
                  environmentFiles = [config.sops.templates."oauth2-proxy.env".path];

                  # It listens above port 1024, so it needs nothing.
                  dropCapabilities = ["ALL"];
                  noNewPrivileges = true;
                };

                # It asks the identity provider who its keys are at startup,
                # and reaches it by the name the proxy answers to, so the
                # proxy is serving before it starts. The proxy needs nothing
                # of it to start in turn: a protected site is answered 502
                # until this is up.
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
        })
      ];
    };
  };
}
