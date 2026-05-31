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
      upstreamPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
        inherit (cfg) extraDependencyGroups;
      };
      runtimePath = lib.makeBinPath (
        (with pkgs; [
          ffmpeg
          git
          nodejs_22
          openssh
          ripgrep
          tirith
        ])
        ++ lib.optionals pkgs.stdenv.isLinux (with pkgs; [
          wl-clipboard
          xclip
        ])
      );
      package =
        if cfg.package != null
        then cfg.package
        else
          upstreamPackage.overrideAttrs (old: {
            pname = "hermes-agent-gateway";
            installPhase = ''
              runHook preInstall

              mkdir -p "$out/bin" "$out/share/hermes-agent"
              cp -r ${inputs.hermes-agent}/skills "$out/share/hermes-agent/skills"
              cp -r ${inputs.hermes-agent}/plugins "$out/share/hermes-agent/plugins"

              for program in hermes hermes-agent hermes-acp; do
                makeWrapper ${upstreamPackage.hermesVenv}/bin/$program "$out/bin/$program" \
                  --suffix PATH : "${runtimePath}" \
                  --set HERMES_BUNDLED_SKILLS "$out/share/hermes-agent/skills" \
                  --set HERMES_BUNDLED_PLUGINS "$out/share/hermes-agent/plugins" \
                  --set HERMES_PYTHON ${upstreamPackage.hermesVenv}/bin/python3
              done

              runHook postInstall
            '';
            passthru =
              old.passthru
              // {
                inherit upstreamPackage;
              };
          });
      extraPackageBinPath = lib.makeBinPath cfg.extraPackages;
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

          exec podman exec "$tty_arg" -u root \
            -e "TERM=''${TERM-}" \
            -e "COLORTERM=''${COLORTERM-}" \
            -e "LANG=''${LANG-}" \
            "${cfg.container.name}" \
            "/data/current-package/bin/$program" "$@"
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
          gnused
        ];
        text =
          ''
            install -d -m 0700 "${cfg.stateDir}"
            install -d -m 0700 "${cfg.stateDir}/.hermes"
            install -d -m 0700 "${cfg.stateDir}/.hermes/cron"
            install -d -m 0700 "${cfg.stateDir}/.hermes/logs"
            install -d -m 0700 "${cfg.stateDir}/.hermes/memories"
            install -d -m 0700 "${cfg.stateDir}/.hermes/plugins"
            install -d -m 0700 "${cfg.stateDir}/.hermes/sessions"
            install -d -m 0700 "${cfg.stateDir}/home"
            install -d -m 0700 "${cfg.workingDirectory}"

            ln -sfn "${package}" "${cfg.stateDir}/current-package"
            install -m 0600 "${generatedConfigFile}" "${cfg.stateDir}/.hermes/config.yaml"

            cat > "${cfg.stateDir}/.hermes/.container-mode" <<'HERMES_CONTAINER_MODE_EOF'
            backend=podman
            container_name=${cfg.container.name}
            exec_user=root
            hermes_bin=/data/current-package/bin/hermes
            HERMES_CONTAINER_MODE_EOF
            sed -i 's/^          //' "${cfg.stateDir}/.hermes/.container-mode"
            chmod 0600 "${cfg.stateDir}/.hermes/.container-mode"

            install -m 0600 "${envFile}" "${cfg.stateDir}/.hermes/.env"
          ''
          + lib.concatMapStrings
          (file: ''
            if [ -f "${file}" ]; then
              printf '\n' >> "${cfg.stateDir}/.hermes/.env"
              cat "${file}" >> "${cfg.stateDir}/.hermes/.env"
            fi
          '')
          cfg.environmentFiles;
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
          home.packages =
            [
              hostCliPackage
              pkgs.fuse-overlayfs
              pkgs.slirp4netns
            ]
            ++ cfg.extraPackages;

          services.podman = {
            enable = true;
            containers.${cfg.container.name} = {
              autoStart = true;
              description = "Hermes Agent Gateway";
              image = cfg.container.image;
              entrypoint = "/data/current-package/bin/hermes";
              exec =
                lib.concatStringsSep " "
                (["gateway" "run" "--replace"] ++ cfg.extraArgs);
              network = cfg.container.network;
              ports = cfg.container.ports;
              volumes =
                [
                  "${cfg.stateDir}:/data"
                  "${cfg.stateDir}/home:/home/hermes"
                  "/nix/store:/nix/store:ro"
                ]
                ++ cfg.container.extraVolumes;
              environment = {
                HOME = "/home/hermes";
                HERMES_CONTAINER = "true";
                HERMES_HOME = "/data/.hermes";
                HERMES_MANAGED = "true";
                MESSAGING_CWD = "/data/workspace";
                PATH = "/data/current-package/bin:${extraPackageBinPath}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
              };
              environmentFile = ["${cfg.stateDir}/.hermes/.env"];
              extraPodmanArgs = cfg.container.extraPodmanArgs;
              extraConfig = {
                Unit = {
                  After = ["network-online.target"];
                  Wants = ["network-online.target"];
                };
                Service = {
                  ExecStartPre = ["${setupScript}/bin/hermes-prepare-state"];
                  Environment = [
                    "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
                  ];
                  TimeoutStopSec = 210;
                };
              };
            };
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
