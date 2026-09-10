# Everything a host says about the Hermes agent: which package to run, what
# goes into its configuration and environment, how its container is
# configured, and which of the feature's children are composed. Each child
# declares its own options under this root, beside the presence option the rest
# of the feature reads.
{
  hostConfig,
  lib,
  options,
  pkgs,
  quadlet,
  ...
}: let
  presence = import ../../lib/presence.nix {inherit lib;};
  yaml = pkgs.formats.yaml {};
in {
  options.dotfiles.hermes = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "${hostConfig.name}/host-hermes.yaml";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file
        containing the agent's secrets. Each platform reads its own keys from
        it and defaults to this file.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Hermes package to run. Null builds the one from the `hermes-agent`
        input with `extraDependencyGroups` and `extraPythonPackages` applied. A
        package given here is used as it is, so neither option affects it.
      '';
    };

    profilePicture = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      example = lib.literalExpression "./hosts/ancaster/godfrey";
      description = "Image file or directory of images to use as the agent's profile picture on supported messaging platforms.";
    };

    settings = lib.mkOption {
      inherit (yaml) type;
      default = {};
      example = lib.literalExpression ''{model.provider = "openai-codex";}'';
      description = ''
        The agent's `config.yaml`, mounted read-only from the store. Several
        modules here write into it and the host writes the rest; the format's
        type merges them by key, so two modules may set different keys under
        one table.
      '';
    };

    environment = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {};
      example = {HERMES_LOG_LEVEL = "debug";};
      description = ''
        Environment variables written into the agent's `.env` before every
        file in `environmentFiles`, so a variable set in both takes the value
        from the file. Values here are written into the world-readable store,
        so a secret belongs in `secretEnv`.
      '';
    };

    environmentFiles = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      description = ''
        Files whose contents are appended to the agent's `.env` at startup, in
        the order the modules defining them are resolved, so the last file
        setting a variable is the one the agent reads. This is how each
        platform hands the agent its sops-rendered secrets.
      '';
    };

    environmentFromState = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {};
      example = {
        MATRIX_RECOVERY_KEY = ".hermes/matrix-recovery-key";
      };
      description = ''
        Environment variables whose values live in files inside the state
        volume, as a map of variable name to path relative to the state
        directory. Each file's content becomes the variable's value when the
        agent starts; variables whose file does not exist yet are left unset.
      '';
    };

    secretEnv = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {};
      example = {
        GROQ_API_KEY = "groq_api_key";
        CONTEXT7_API_KEY = "context7_api_key";
      };
      description = ''
        Environment variables sourced from sops, as a map of environment
        variable name to the sops key its value comes from. The values are read
        from `secretEnvFile` and rendered into the agent's environment.
      '';
    };

    secretEnvFile = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "ancaster/user-hermes.yaml";
      description = "Path, relative to the `secrets` input, of the sops file backing `secretEnv`.";
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      example = ["--verbose"];
      description = "Arguments appended to the gateway's `hermes gateway run` command line.";
    };

    extraDependencyGroups = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      example = ["matrix"];
      description = ''
        Optional dependency groups from the package's `pyproject.toml` built
        into the agent, on top of the `all` group it always gets. A platform
        or backend that needs a Python client names its group here: the Matrix
        platform adds `matrix`, and the Exa web-search backend `exa`.

        This list replaces the package's default dependency groups, so a group
        absent from both this list and `all` is not installed.
      '';
    };

    extraPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [];
      description = ''
        Packages added to the agent's image and PATH, and to the host profile.
        For tools the agent should be able to run, prefer `agentPackages`.
      '';
    };

    extraPlugins = lib.mkOption {
      type = with lib.types; attrsOf (either path package);
      default = {};
      example = {
        hermes-lcm = "<hermes-lcm input>";
      };
      description = ''
        Directory-based plugin source trees to symlink into the Hermes plugin
        directory. Each entry must contain `plugin.yaml` at its root.
      '';
    };

    extraPythonPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [];
      example = lib.literalExpression "[pkgs.python312Packages.tiktoken]";
      description = ''
        Python packages added to the agent's import path, for optional
        dependencies a plugin can use that the package's own virtual
        environment does not contain. They must come from the same Python as
        the package (`python312Packages`).
      '';
    };

    agentPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [];
      example = lib.literalExpression "[pkgs.jq pkgs.fd]";
      description = ''
        Programs the agent can run inside the container, on top of the
        package's own runtime tools (git, node, ripgrep, ffmpeg, ...). They
        are baked into the image and put on the container PATH so they
        resolve by name. `core.nix` adds curl and wget.
      '';
    };

    container = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "hermes-agent";
        description = ''
          Name of the gateway's podman container, and the name the other
          containers and the host CLI reach it by.
        '';
      };

      network = lib.mkOption {
        type = with lib.types; either str (listOf str);
        default = [];
        example = ["hermesnet.network"];
        description = ''
          podman networks the gateway, the dashboard and the profile-picture
          helper join, as quadlet writes them. The signal-cli network is added
          on top wherever the Signal platform is composed.
        '';
      };

      ports = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        example = ["127.0.0.1:8000:8000"];
        description = ''
          Ports the gateway container publishes on the host, as podman takes
          them. Nothing here is published by default: the agent is reached
          through the host CLI and the platforms it connects out to.
        '';
      };

      extraVolumes = lib.mkOption {
        type = lib.types.listOf quadlet.mountType;
        default = [];
        example = [
          {
            source.bind = "/srv/hermes";
            target = "/srv/hermes";
            readOnly = true;
          }
        ];
        description = "Additional typed mounts for each Hermes application container.";
      };

      extraPodmanArgs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        example = ["--shm-size=1g"];
        description = ''
          Arguments passed straight to `podman run` for each Hermes container,
          for settings that quadlet does not expose.
        '';
      };

      extraSetup = lib.mkOption {
        type = lib.types.lines;
        default = "";
        internal = true;
        description = "Shell appended to the host-side Hermes state setup script.";
      };

      noNewPrivileges = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Set `no-new-privileges`, so a process the agent execs cannot gain
          privileges through setuid binaries or file capabilities.
        '';
      };

      memory = lib.mkOption {
        type = with lib.types; nullOr str;
        default = "4g";
        example = "2g";
        description = "Container memory limit (podman `--memory`). Null leaves it unlimited.";
      };

      pidsLimit = lib.mkOption {
        type = with lib.types; nullOr int;
        default = 1024;
        description = "Maximum number of processes (podman `--pids-limit`). Null uses the podman default.";
      };
    };

    signal.present = presence.option "the Signal platform, backed by a signal-cli daemon sidecar";
    webhook.present = presence.option "the signed HTTP webhook platform";
    matrix.present = presence.option "the Matrix platform";
    dashboard.present = presence.option "the Hermes web dashboard, in a container of its own";
    homeassistant.present = presence.option "the Home Assistant integration, an event platform and device-control tools";
    identity.present = presence.option "the agent's Git and SSH identity";
    soul.present = presence.option "the read-only SOUL.md identity file";
    agents.present = presence.option "the read-only AGENTS.md operating-instructions file";
    agentsview.present = presence.option "archiving the agent's sessions in AgentsView";
    mcp.present = presence.option "the default MCP server set: Exa, Cloudflare, Context7 and a local mcp-nixos";
    embeddings.present = presence.option "semantic and hybrid retrieval in the LCM context engine";
    backup.present = presence.option "encrypted backups of the agent state, uploaded to Cloudflare R2";

    contextEngine = lib.mkOption {
      type = lib.types.enum ["compressor" "lcm"];
      default = "compressor";
      description = "Context engine to use for conversation context management.";
    };
  };

  config.assertions =
    presence.assertions options
    (map (child: ["dotfiles" "hermes" child "present"]) [
      "signal"
      "webhook"
      "matrix"
      "dashboard"
      "homeassistant"
      "identity"
      "soul"
      "agents"
      "agentsview"
      "mcp"
      "embeddings"
      "backup"
    ]);
}
