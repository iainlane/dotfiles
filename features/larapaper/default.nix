# LaraPaper, the self-hosted TRMNL server, served on the host's LAN address.
#
# A TRMNL device is given a server URL and fetches screens over plain HTTP. The
# container publishes its port on the host's LAN address for that device, and
# the same address becomes `APP_URL`. The SQLite database and the generated
# images live in named volumes; the backup child uploads them to Cloudflare R2.
{config, ...}: let
  inherit (config.flake) features;
in {
  imports = [./backup];

  flake.features.larapaper = {
    includes = [
      features.containers
      # The port defaults to the host's LAN address, which the network feature
      # derives.
      features.network
      features.larapaper.provides.backup
    ];

    systemManager = {
      config,
      inputs,
      lib,
      quadlet,
      ...
    }: let
      cfg = config.dotfiles.larapaper;
      paths = import ./paths.nix;

      secretsFile = inputs.secrets + "/${cfg.secretsFile}";

      # renovate: datasource=docker depName=ghcr.io/usetrmnl/larapaper versioning=docker
      tag = "0.42.0@sha256:2e0bd58aff9feaa082fc5e19aab6b91144ff2dab91939c8c610d72e2264d5a9e";
      image = "ghcr.io/usetrmnl/larapaper:${tag}";

      envTemplate = "larapaper.env";

      secretLines =
        lib.optionals (builtins.pathExists secretsFile)
        (lib.splitString "\n" (builtins.readFile secretsFile));
    in {
      imports = [./options.nix];

      config = {
        assertions = [
          {
            assertion =
              builtins.pathExists secretsFile
              && lib.any (line: lib.hasPrefix "${cfg.appKeyKey}:" line) secretLines;
            message = ''
              The sops file ${cfg.secretsFile} is missing from the secrets
              repository, or it has no ${cfg.appKeyKey}. Create it with this
              key:
                ${cfg.appKeyKey}: base64:<32 random bytes, base64-encoded>
            '';
          }
        ];

        sops = {
          secrets.${cfg.appKeyKey}.sopsFile = secretsFile;

          # Laravel reads `APP_KEY` from the process environment. The container
          # mounts the rendered file, so the key never reaches the store or the
          # unit's command line.
          templates.${envTemplate}.content = ''
            APP_KEY=${config.sops.placeholder.${cfg.appKeyKey}}
          '';
        };

        virtualisation.quadlet = {
          networks.larapapernet = {};

          volumes = {
            ${paths.databaseVolume} = {};
            ${paths.storageVolume} = {};
          };

          containers.${cfg.containerName} = {
            autoStart = true;

            containerConfig = {
              inherit image;

              networks = [config.virtualisation.quadlet.networks.larapapernet.ref];

              # The address is `listenAddress`, so a host that also has a routed
              # public address does not serve LaraPaper there.
              publishPorts = [
                "${cfg.listenAddress}:${toString cfg.port}:${toString paths.containerPort}"
              ];

              volumes = quadlet.mounts [
                {
                  source.quadletVolume = paths.databaseVolume;
                  target = paths.databaseDir;
                }
                {
                  source.quadletVolume = paths.storageVolume;
                  target = paths.storageDir;
                }
              ];

              environments = {
                APP_ENV = "production";
                APP_DEBUG = "false";
                APP_URL = cfg.appUrl;
                DB_CONNECTION = "sqlite";
                DB_DATABASE = "database/storage/database.sqlite";
                PHP_OPCACHE_ENABLE = "1";
                TRMNL_PROXY_REFRESH_MINUTES = "15";
              };

              environmentFiles = [config.sops.templates.${envTemplate}.path];

              # The container listens above port 1024, so it needs no
              # capabilities.
              dropCapabilities = ["ALL"];
              noNewPrivileges = true;
            };

            unitConfig = {
              Description = "LaraPaper TRMNL server";
              After = ["network-online.target" "sops-install-secrets.service"];
              Wants = ["network-online.target" "sops-install-secrets.service"];
            };
          };
        };
      };
    };
  };
}
