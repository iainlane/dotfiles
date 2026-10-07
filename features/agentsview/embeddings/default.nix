# Builds a semantic-search embedding index over one machine's archive and
# pushes it alongside the rest, through OpenRouter's OpenAI-compatible
# embeddings endpoint unless the machine also has the `local` child, which
# switches it to a local Ollama server instead.
{
  config,
  lib,
  ...
}: let
  common = import ../common.nix {
    inherit lib;
    inherit (config.flake) features;
  };

  envTemplate = "agentsview-embeddings.env";

  agentsviewFor = inputs: system: inputs.llm-agents.packages.${system}.agentsview;

  homeManager = {
    config,
    hostConfig,
    inputs,
    lib,
    ...
  }: let
    usesOpenRouter = !common.hasLocalEmbeddings hostConfig;
  in {
    config.sops = lib.mkIf usesOpenRouter {
      secrets.${common.embeddings.apiKeySecretName} = {
        sopsFile = inputs.secrets + "/${common.embeddings.secretsFile}";
        key = common.embeddings.apiKeySecret;
      };

      templates.${envTemplate}.content = ''
        ${common.embeddings.backends.openrouter.apiKeyEnvironment}=${config.sops.placeholder.${common.embeddings.apiKeySecretName}}
      '';
    };
  };

  # A systemd user timer, for the Linux kernel `client.nix`'s own push service
  # also runs under. Incremental: with no `--full-rebuild`, `embeddings build`
  # only embeds documents new since the last run, so the half-hour interval
  # costs nothing on a quiet archive.
  systemdModule = {
    config,
    hostConfig,
    inputs,
    lib,
    pkgs,
    system,
    ...
  }: let
    cfg = config.dotfiles.agentsview;
    usesOpenRouter = !common.hasLocalEmbeddings hostConfig;
    agentsview = agentsviewFor inputs system;
    probe = lib.escapeShellArgs ([
        "${pkgs.python3}/bin/python3"
        "${./local/check.py}"
        "--endpoint"
        (lib.removeSuffix "/v1" common.embeddings.backends.local.endpoint)
        "--model"
        common.embeddings.model
        "--dimension"
        (toString common.embeddings.dimension)
      ]
      ++ lib.optional config.dotfiles.inference.ollama.requireAcceleration "--require-acceleration");
  in {
    config = {
      systemd.user.services.agentsview-embed = {
        Unit = {
          Description = "Build the AgentsView semantic-search embedding index";
          After = lib.optional (!usesOpenRouter) "ollama-model-loader.service";
          Requires = lib.optional (!usesOpenRouter) "ollama-model-loader.service";
        };

        Service =
          {
            Type = "oneshot";
            Environment = ["AGENTSVIEW_DATA_DIR=${cfg.dataDir}"];
            ExecStart = "${agentsview}/bin/agentsview embeddings build --yes";
          }
          // lib.optionalAttrs usesOpenRouter {
            EnvironmentFile = config.sops.templates.${envTemplate}.path;
          }
          // lib.optionalAttrs (!usesOpenRouter) {
            ExecStartPre = probe;
          };
      };

      systemd.user.timers.agentsview-embed = {
        Unit.Description = "Schedule the AgentsView embedding build";
        Install.WantedBy = ["timers.target"];

        Timer = {
          OnStartupSec = "5m";
          OnUnitActiveSec = "30m";
          Persistent = true;
        };
      };
    };
  };

  # launchd has no direct equivalent of `EnvironmentFile=`, so the OpenRouter
  # backend sources its sops-rendered secret itself before running the build;
  # the local backend needs no key at all.
  launchdModule = {
    config,
    hostConfig,
    inputs,
    system,
    ...
  }: let
    cfg = config.dotfiles.agentsview;
    usesOpenRouter = !common.hasLocalEmbeddings hostConfig;
    agentsview = agentsviewFor inputs system;
    logDir = "${config.home.homeDirectory}/Library/Logs";

    build = "exec \"${agentsview}/bin/agentsview\" embeddings build --yes";
  in {
    config = {
      launchd.agents.agentsview-embed = {
        enable = true;
        config = {
          ProgramArguments = [
            "/bin/sh"
            "-c"
            (
              if usesOpenRouter
              then ''set -a; . "${config.sops.templates.${envTemplate}.path}"; set +a; ${build}''
              else build
            )
          ];
          EnvironmentVariables.AGENTSVIEW_DATA_DIR = cfg.dataDir;
          StartInterval = 1800;
          StandardOutPath = "${logDir}/agentsview-embed.log";
          StandardErrorPath = "${logDir}/agentsview-embed.log";
        };
      };
    };
  };
in {
  imports = [./local];

  flake.features.agentsview.provides.embeddings = {
    inherit homeManager;
    kernel.linux.homeManager = systemdModule;
    kernel.darwin.homeManager = launchdModule;
  };
}
