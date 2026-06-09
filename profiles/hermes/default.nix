{
  flake.profiles.hermes = {
    requires = [
      {
        profile = "containers";
        os = ["linux"];
      }
    ];

    os.linux.homeManagerModule = args: {
      config,
      inputs,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.hermes-agent;
      yaml = pkgs.formats.yaml {};
      generatedConfigFile = yaml.generate "hermes-config.yaml" cfg.settings;
      # Add an extra Python package as a leaf on the agent's import path: drop
      # its propagated deps so they cannot duplicate packages the sealed venv
      # already ships, which the package's collision check rejects. Shared deps
      # resolve from the venv at import; a dependency the venv lacks must be its
      # own `extraPythonPackages` entry.
      venvLeafPackage = pkg:
        pkg.overridePythonAttrs (_: {
          dependencies = [];
          propagatedBuildInputs = [];
          # The package is built without its declared deps, so skip the build's
          # own dependency and test checks; they are satisfied at the agent's
          # assembled import path, not by the package in isolation.
          doCheck = false;
          dontCheckRuntimeDeps = true;
        });
      package =
        if cfg.package != null
        then cfg.package
        else
          inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
            inherit (cfg) extraDependencyGroups;
            extraPythonPackages = map venvLeafPackage cfg.extraPythonPackages;
          };
      # Each container runs from a self-contained layered image built from the
      # Nix closure, loaded via a `podman.images` quadlet. There is no host
      # `/nix/store` bind mount; the package lives inside the image at its store
      # path.
      # No `tag` is given, so buildLayeredImage derives a content-addressed
      # `imageTag`. Containers reference that tag, so a changed image flips the
      # tag, which changes the container unit and triggers a restart on deploy.
      mkNixImage = name: contents:
        pkgs.dockerTools.buildLayeredImage {
          inherit name contents;
          # A generic base image ships /tmp; a layered image does not. signal-cli
          # (sqlite-jdbc) extracts a native library there at startup, so create a
          # world-writable /tmp.
          extraCommands = "mkdir -m 1777 tmp";
        };
      # A fixed in-container service user. The host user is mapped onto this uid
      # via `keep-id:uid=…`, so the container runs as `hermes` (non-root) while
      # still owning the host-side state. `fakeNss` already provides root and
      # nobody plus nsswitch.conf; we just add the `hermes` line.
      hermesUser = "hermes";
      hermesUid = 1000;
      hermesNss = pkgs.dockerTools.fakeNss.override {
        extraPasswdLines = ["${hermesUser}:x:${toString hermesUid}:${toString hermesUid}:${hermesUser}:/home/hermes:/bin/sh"];
        extraGroupLines = ["${hermesUser}:x:${toString hermesUid}:"];
      };
      hermesUserNS = "keep-id:uid=${toString hermesUid},gid=${toString hermesUid}";
      # Podman-managed named volumes hold the durable state. The setup step and
      # backup resolve their mountpoints at runtime via `podman volume inspect`.
      hermesStateVolume = "hermes-state";
      hermesHomeVolume = "hermes-home";
      hermesCacheVolume = "hermes-cache";
      signalStateVolume = "signal-state";
      hermesBinDir = "${package}/bin";
      # Tools the agent can shell out to, on top of the package's own runtime
      # deps (git/node/ripgrep/ffmpeg/...). `agentPackages` are nixpkgs
      # attribute names; they go into the image and onto the container PATH so
      # they resolve by name for the agent.
      agentToolDrvs =
        map (name: pkgs.${name}) cfg.agentPackages
        ++ cfg.extraPackages;
      agentBinPath = lib.makeBinPath agentToolDrvs;
      # extraPlugins are symlinked into the state dir by the setup script using
      # their store paths. The container has no host /nix/store, so carry those
      # paths into the image closure here (buildLayeredImage ships the whole
      # closure), otherwise the symlinks dangle inside the container. linkFarm
      # references the plugins as real build inputs, so the closure includes
      # them even though their paths reach the script context-free.
      extraPluginPaths = pkgs.linkFarm "hermes-extra-plugins" (
        lib.mapAttrsToList (name: path: {inherit name path;}) cfg.extraPlugins
      );
      hermesImage = mkNixImage cfg.container.name (
        [
          package
          pkgs.bashInteractive
          # A common Unix userland the agent shells out to, on top of the
          # package's own runtime deps. The minimal image ships none of these.
          pkgs.coreutils
          pkgs.diffutils
          pkgs.file
          pkgs.findutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.less
          pkgs.perl
          pkgs.python3
          pkgs.which
          pkgs.dockerTools.binSh
          pkgs.dockerTools.caCertificates
          hermesNss
        ]
        ++ agentToolDrvs
        ++ lib.optional cfg.mcp.enable pkgs.mcp-nixos
        ++ lib.optional (cfg.extraPlugins != {}) extraPluginPaths
      );
      hermesImageRef = "localhost/${cfg.container.name}:${hermesImage.imageTag}";
      hermesImageUnit = "podman-${cfg.container.name}-image.service";
      signalImage = mkNixImage cfg.signal.containerName [
        signalCliPackage
        pkgs.coreutils
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        hermesNss
      ];
      signalImageRef = "localhost/${cfg.signal.containerName}:${signalImage.imageTag}";
      signalImageUnit = "podman-${cfg.signal.containerName}-image.service";
      # Sandbox hardening shared by every container: no capabilities, no
      # privilege gain on exec, and resource caps.
      hardeningPodmanArgs =
        lib.optional cfg.container.noNewPrivileges "--security-opt=no-new-privileges"
        ++ lib.optional (cfg.container.memory != null) "--memory=${cfg.container.memory}"
        ++ lib.optional (cfg.container.pidsLimit != null) "--pids-limit=${toString cfg.container.pidsLimit}";
      hostCliPackage = pkgs.writeShellApplication {
        name = "hermes-agent-container-cli";
        runtimeInputs = [pkgs.podman];
        text = ''
          program="$(basename "$0")"

          case "$program" in
            hermes|hermes-agent|hermes-acp) ;;
            *) program="hermes" ;;
          esac

          tty_arg="-i"
          if [ -t 0 ]; then
            tty_arg="-it"
          fi

          exec podman exec "$tty_arg" -u ${hermesUser} \
            -e "TERM=''${TERM-}" \
            -e "COLORTERM=''${COLORTERM-}" \
            -e "LANG=''${LANG-}" \
            "${cfg.container.name}" \
            "${hermesBinDir}/$program" "$@"
        '';
        derivationArgs = {
          postInstall = ''
            ln -s hermes-agent-container-cli "$out/bin/hermes"
            ln -s hermes-agent-container-cli "$out/bin/hermes-agent"
            ln -s hermes-agent-container-cli "$out/bin/hermes-acp"
          '';
        };
      };
      envFile = pkgs.writeText "hermes-env" (
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList
          (name: value: "${name}=${value}")
          cfg.environment
        )
      );
      setupScript = pkgs.writeShellApplication {
        name = "hermes-prepare-state";
        runtimeInputs = with pkgs; [
          coreutils
          findutils
          gnused
          podman
        ];
        text =
          ''
            state="$(podman volume inspect --format '{{.Mountpoint}}' ${hermesStateVolume})"

            install -d -m 0700 "$state/.hermes"
            install -d -m 0700 "$state/.hermes/cron"
            install -d -m 0700 "$state/.hermes/logs"
            install -d -m 0700 "$state/.hermes/memories"
            install -d -m 0700 "$state/.hermes/plugins"
            install -d -m 0700 "$state/.hermes/sessions"
            install -d -m 0700 "$state/workspace"

            ln -sfn "${package}" "$state/current-package"

            # The skill curator materialises bundled skills read-only (copied
            # from the read-only image). Make the tree writable so the agent can
            # author and edit skills in place.
            if [ -d "$state/.hermes/skills" ]; then
              chmod -R u+w "$state/.hermes/skills"
            fi

            cat > "$state/.hermes/.container-mode" <<'HERMES_CONTAINER_MODE_EOF'
            backend=podman
            container_name=${cfg.container.name}
            exec_user=${hermesUser}
            hermes_bin=${hermesBinDir}/hermes
            HERMES_CONTAINER_MODE_EOF
            sed -i 's/^          //' "$state/.hermes/.container-mode"
            chmod 0600 "$state/.hermes/.container-mode"

            install -m 0600 "${envFile}" "$state/.hermes/.env"
          ''
          + lib.concatMapStrings
          (file: ''
            if [ -f "${file}" ]; then
              printf '\n' >> "$state/.hermes/.env"
              cat "${file}" >> "$state/.hermes/.env"
            fi
          '')
          cfg.environmentFiles
          + ''

            find "$state/.hermes/plugins" -maxdepth 1 -type l -name 'nix-managed-*' -delete
          ''
          + lib.concatStringsSep "\n" (
            lib.mapAttrsToList
            (name: plugin: ''
              if [ ! -f "${plugin}/plugin.yaml" ]; then
                echo "ERROR: extraPlugins entry '${name}' has no plugin.yaml" >&2
                exit 1
              fi
              ln -sfn "${plugin}" "$state/.hermes/plugins/nix-managed-${name}"
            '')
            cfg.extraPlugins
          );
      };
      signalCliPackage =
        if cfg.signal.package != null
        then cfg.signal.package
        else pkgs.signal-cli;
      signalSecretsFile = inputs.secrets + "/${cfg.signal.secretsFile}";
      hassSecretsFile = inputs.secrets + "/${cfg.homeassistant.secretsFile}";
      backupSecretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
      # The script reads its config from the environment, so it stays a plain
      # checkable shell file. The systemd service supplies the non-secret values
      # and the sops env file supplies the R2 credentials.
      backupScript = pkgs.writeShellApplication {
        name = "hermes-backup-r2";
        runtimeInputs = with pkgs; [coreutils rsync sqlite zstd gnutar rclone age podman];
        text = builtins.readFile ./backup-r2.sh;
      };
      # Both the gateway and the dashboard are the same image and the same
      # `hermes` binary run with a different sub-command. This builds the shared
      # container definition; callers vary only the sub-command, ports, and a
      # few unit knobs.
      mkHermesContainer = {
        description,
        exec,
        network ? [],
        ports ? [],
        environment ? {},
        after ? [],
        service ? {},
      }: {
        autoStart = true;
        inherit description exec network ports;
        image = hermesImageRef;
        # Run as the fixed `hermes` user (non-root inside), mapped to the host
        # user so it can write its state mounts but not its own system paths.
        user = hermesUser;
        userNS = hermesUserNS;
        entrypoint = "${hermesBinDir}/hermes";
        volumes =
          [
            "${hermesStateVolume}.volume:/data"
            "${hermesHomeVolume}.volume:/home/hermes"
            "${hermesCacheVolume}.volume:/data/.hermes/cache"
            # config.yaml and SOUL.md come straight from the Nix store, read
            # only. Hermes never writes them, and a change flips the store path,
            # so the unit changes and the container restarts to pick it up.
            "${generatedConfigFile}:/data/.hermes/config.yaml:ro"
          ]
          ++ lib.optional cfg.soul.enable "${cfg.soul.file}:/data/.hermes/SOUL.md:ro"
          ++ lib.optional cfg.agents.enable "${cfg.agents.file}:/data/workspace/AGENTS.md:ro"
          ++ cfg.container.extraVolumes;
        environment =
          {
            HOME = "/home/hermes";
            HERMES_CONTAINER = "true";
            HERMES_HOME = "/data/.hermes";
            HERMES_MANAGED = "true";
            PATH = "${hermesBinDir}:${agentBinPath}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
          }
          // environment;
        # Hermes loads /data/.hermes/.env into its environment itself, so no
        # podman env-file is needed; the file lives in the state volume.
        dropCapabilities = ["ALL"];
        extraPodmanArgs = hardeningPodmanArgs ++ cfg.container.extraPodmanArgs;
        extraConfig = {
          Unit = {
            After = ["network-online.target" "sops-nix.service" hermesImageUnit] ++ after;
            Wants = ["network-online.target" "sops-nix.service" hermesImageUnit] ++ after;
          };
          Service =
            {
              ExecStartPre = ["${setupScript}/bin/hermes-prepare-state"];
              Environment = [
                "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
              ];
            }
            // service;
        };
      };
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {
          services.hermes-agent =
            {
              enable = lib.mkDefault true;
            }
            // args;
        }
        (lib.mkIf cfg.enable {
          # The agent's terminal working directory, inside the container.
          services.hermes-agent.settings.terminal.cwd = "/data/workspace";

          home.packages =
            [
              hostCliPackage
              pkgs.fuse-overlayfs
              pkgs.slirp4netns
            ]
            ++ cfg.extraPackages;

          services.podman = {
            enable = true;
            volumes = {
              ${hermesStateVolume} = {
                description = "Hermes Agent durable state";
              };
              ${hermesHomeVolume} = {
                description = "Hermes Agent home directory";
              };
              ${hermesCacheVolume} = {
                description = "Hermes Agent attachment cache, shared with signal-cli";
              };
            };
            images.${cfg.container.name} = {
              image = "docker-archive:${hermesImage}";
              autoStart = true;
            };
            containers.${cfg.container.name} = mkHermesContainer {
              description = "Hermes Agent Gateway";
              exec =
                lib.concatStringsSep " "
                (["gateway" "run" "--replace"] ++ cfg.extraArgs);
              network =
                lib.toList cfg.container.network
                ++ lib.optional cfg.signal.enable "${cfg.signal.network}.network";
              ports = cfg.container.ports;
              service.TimeoutStopSec = 210;
            };
          };
        })
        (lib.mkIf (cfg.enable && cfg.dashboard.enable) {
          services.podman.containers.${cfg.dashboard.containerName} = mkHermesContainer {
            description = "Hermes Agent Web Dashboard";
            exec = lib.concatStringsSep " " [
              "dashboard"
              "--host"
              "0.0.0.0"
              "--port"
              (toString cfg.dashboard.port)
              "--no-open"
              "--insecure"
              "--skip-build"
            ];
            ports = ["${cfg.dashboard.address}:${toString cfg.dashboard.port}:${toString cfg.dashboard.port}"];
            after = [
              "podman-${cfg.container.name}.service"
            ];
          };
        })
        (lib.mkIf (cfg.enable && cfg.signal.enable) {
          home.packages = [signalCliPackage];

          sops = {
            secrets = {
              signal_account.sopsFile = signalSecretsFile;
              signal_allowed_users.sopsFile = signalSecretsFile;
              signal_home_channel.sopsFile = signalSecretsFile;
            };

            templates."hermes-signal.env".content = ''
              SIGNAL_ACCOUNT=${config.sops.placeholder.signal_account}
              SIGNAL_ALLOWED_USERS=${config.sops.placeholder.signal_allowed_users}
              SIGNAL_HOME_CHANNEL=${config.sops.placeholder.signal_home_channel}
            '';
          };

          services.hermes-agent = {
            environment.SIGNAL_HTTP_URL = cfg.signal.httpUrl;
            environmentFiles = [config.sops.templates."hermes-signal.env".path];
          };

          services.podman = {
            volumes.${signalStateVolume} = {
              description = "signal-cli account state";
            };

            networks.${cfg.signal.network} = {
              description = "Hermes and signal-cli network";
              extraConfig.Service.Environment = {
                PATH = "/usr/local/libexec/podman:/run/wrappers/bin:/usr/bin:/bin:/usr/sbin:/sbin";
              };
            };

            images.${cfg.signal.containerName} = {
              image = "docker-archive:${signalImage}";
              autoStart = true;
            };

            containers.${cfg.signal.containerName} = {
              autoStart = true;
              description = "signal-cli JSON-RPC daemon for Hermes";
              image = signalImageRef;
              user = hermesUser;
              userNS = hermesUserNS;
              entrypoint = "${signalCliPackage}/bin/signal-cli";
              exec = "--config /data daemon --http 0.0.0.0:8080";
              network = ["${cfg.signal.network}.network"];
              volumes = [
                "${signalStateVolume}.volume:/data"
                # Hermes writes outgoing attachments under /data/.hermes/cache in
                # its own namespace and hands signal-cli that path, so the shared
                # cache volume resolves them to the same files here.
                "${hermesCacheVolume}.volume:/data/.hermes/cache:ro"
              ];
              environment.HOME = "/data";
              dropCapabilities = ["ALL"];
              extraPodmanArgs = hardeningPodmanArgs;
              extraConfig = {
                Unit = {
                  After = ["network-online.target" signalImageUnit];
                  Wants = ["network-online.target" signalImageUnit];
                };
                Service = {
                  Environment = [
                    "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
                  ];
                };
              };
            };
          };
        })
        (lib.mkIf (cfg.enable && cfg.homeassistant.enable) {
          sops = {
            secrets = {
              hass_token.sopsFile = hassSecretsFile;
              hass_url.sopsFile = hassSecretsFile;
            };

            templates."hermes-homeassistant.env".content = ''
              HASS_TOKEN=${config.sops.placeholder.hass_token}
              HASS_URL=${config.sops.placeholder.hass_url}
            '';
          };

          services.hermes-agent.environmentFiles = [
            config.sops.templates."hermes-homeassistant.env".path
          ];
        })
        (lib.mkIf (cfg.enable && cfg.secretEnvFile != null && cfg.secretEnv != {}) {
          sops = {
            secrets =
              lib.mapAttrs' (
                _: sopsKey:
                  lib.nameValuePair sopsKey {
                    sopsFile = inputs.secrets + "/${cfg.secretEnvFile}";
                  }
              )
              cfg.secretEnv;

            templates."hermes-secret.env".content =
              lib.concatStringsSep "\n" (
                lib.mapAttrsToList
                (envVar: sopsKey: "${envVar}=${config.sops.placeholder.${sopsKey}}")
                cfg.secretEnv
              )
              + "\n";
          };

          services.hermes-agent.environmentFiles = [
            config.sops.templates."hermes-secret.env".path
          ];
        })
        (lib.mkIf (cfg.enable && cfg.mcp.enable) {
          services.hermes-agent.settings.mcp_servers = {
            exa.url = "https://mcp.exa.ai/mcp";
            cloudflare.url = "https://docs.mcp.cloudflare.com/mcp";
            context7.url = "https://mcp.context7.com/mcp";
            nixos = {
              command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
              args = [];
            };
          };
        })
        (lib.mkIf (cfg.enable && cfg."context-engine" == "lcm") {
          services.hermes-agent = {
            extraPlugins.hermes-lcm = inputs.hermes-lcm;
            # hermes-lcm uses tiktoken for exact token counts and regex for
            # message ignore patterns.
            extraPythonPackages = [
              pkgs.python312Packages.tiktoken
              pkgs.python312Packages.regex
            ];
            settings = {
              plugins.enabled = ["hermes-lcm"];
              context.engine = "lcm";
            };
          };
        })
        (lib.mkIf (cfg.enable && cfg.backup.enable) {
          sops = {
            secrets = {
              r2_bucket.sopsFile = backupSecretsFile;
              r2_endpoint.sopsFile = backupSecretsFile;
              r2_access_key_id.sopsFile = backupSecretsFile;
              r2_secret_access_key.sopsFile = backupSecretsFile;
            };

            templates."hermes-backup.env".content = ''
              R2_BUCKET=${config.sops.placeholder.r2_bucket}
              R2_ENDPOINT=${config.sops.placeholder.r2_endpoint}
              R2_ACCESS_KEY_ID=${config.sops.placeholder.r2_access_key_id}
              R2_SECRET_ACCESS_KEY=${config.sops.placeholder.r2_secret_access_key}
            '';
          };

          systemd.user.services.hermes-backup = {
            Unit = {
              Description = "Back up Hermes state to Cloudflare R2";
              After = ["network-online.target" "sops-nix.service"];
              Wants = ["network-online.target"];
            };
            Service = {
              Type = "oneshot";
              EnvironmentFile = config.sops.templates."hermes-backup.env".path;
              Environment = [
                "HERMES_STATE_VOLUME=${hermesStateVolume}"
                "HERMES_BACKUP_AGE_RECIPIENT=${cfg.backup.ageRecipient}"
                "HERMES_BACKUP_PREFIX=${cfg.backup.prefix}"
                "HERMES_BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
              ];
              ExecStart = "${backupScript}/bin/hermes-backup-r2";
            };
          };

          systemd.user.timers.hermes-backup = {
            Unit.Description = "Schedule the Hermes R2 backup";
            Timer = {
              OnCalendar = cfg.backup.schedule;
              Persistent = true;
            };
            Install.WantedBy = ["timers.target"];
          };
        })
      ];
    };

    os.linux.systemManagerModule = {
      lib,
      username,
      ...
    }: {
      config.users.users.${username} = {
        autoSubUidGidRange = lib.mkDefault true;
        linger = lib.mkDefault true;
      };
    };
  };
}
