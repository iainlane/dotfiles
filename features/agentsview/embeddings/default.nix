# Builds a semantic-search embedding index over one machine's archive and
# pushes it alongside the rest, through OpenRouter's OpenAI-compatible
# embeddings endpoint.
#
# This is opt-in: sending archived session text to OpenRouter is a choice
# each host makes for itself, not something every `agentsview` host should do,
# so a host lists this child explicitly rather than getting it through
# `agentsview`'s own `includes`.
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
    inputs,
    ...
  }: {
    config.sops = {
      secrets.${common.embeddings.apiKeySecretName} = {
        sopsFile = inputs.secrets + "/${common.embeddings.secretsFile}";
        key = common.embeddings.apiKeySecret;
      };

      templates.${envTemplate}.content = ''
        ${common.embeddings.apiKeyEnvironment}=${config.sops.placeholder.${common.embeddings.apiKeySecretName}}
      '';
    };
  };

  # A systemd user timer, for the Linux kernel `client.nix`'s own push service
  # also runs under. Incremental: with no `--full-rebuild`, `embeddings build`
  # only embeds documents new since the last run, so the half-hour interval
  # costs nothing on a quiet archive.
  systemdModule = {
    config,
    inputs,
    system,
    ...
  }: let
    cfg = config.dotfiles.agentsview;
    agentsview = agentsviewFor inputs system;
  in {
    config = {
      systemd.user.services.agentsview-embed = {
        Unit.Description = "Build the AgentsView semantic-search embedding index";

        Service = {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates.${envTemplate}.path;
          Environment = ["AGENTSVIEW_DATA_DIR=${cfg.dataDir}"];
          ExecStart = "${agentsview}/bin/agentsview embeddings build --yes";
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

  # launchd has no direct equivalent of `EnvironmentFile=`, so the job sources
  # the sops-rendered secret itself before running the build.
  launchdModule = {
    config,
    inputs,
    system,
    ...
  }: let
    cfg = config.dotfiles.agentsview;
    agentsview = agentsviewFor inputs system;
    logDir = "${config.home.homeDirectory}/Library/Logs";
  in {
    config = {
      launchd.agents.agentsview-embed = {
        enable = true;
        config = {
          ProgramArguments = [
            "/bin/sh"
            "-c"
            ''set -a; . "${config.sops.templates.${envTemplate}.path}"; set +a; exec "${agentsview}/bin/agentsview" embeddings build --yes''
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
  flake.features.agentsview.provides.embeddings = {
    inherit homeManager;
    kernel.linux.homeManager = systemdModule;
    kernel.darwin.homeManager = launchdModule;
  };
}
