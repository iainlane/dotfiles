{
  hostConfig,
  lib,
  options,
  pkgs,
  ...
}: let
  quadlet = import ../../lib/quadlet.nix {inherit lib;};
  presence = import ../../lib/presence.nix {inherit lib;};
  yaml = pkgs.formats.yaml {};
in {
  options.dotfiles.hermes = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "${hostConfig.name}/host-hermes.yaml";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file holding
        the agent's secrets. Each platform reads its own keys from it and
        defaults to this file.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
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
    };

    environment = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {};
    };

    environmentFiles = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
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
        variable name to the sops key holding its value. The values are read
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
    };

    extraDependencyGroups = lib.mkOption {
      type = with lib.types; listOf str;
      default = ["messaging"];
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

    enabledPlugins = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      example = ["hermes-lcm"];
      description = ''
        Plugin names to add to the agent's `plugins.enabled` allow-list.
        Plugins are opt-in: a plugin must appear here before the agent loads
        it.
      '';
    };

    disabledPlugins = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      example = ["raft-platform"];
      description = ''
        Plugin names to add to the agent's `plugins.disabled` list. A disabled
        plugin is skipped during discovery, which also suppresses any
        startup probing it would otherwise perform.
      '';
    };

    extraPythonPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [];
      example = lib.literalExpression "[pkgs.python312Packages.tiktoken]";
      description = ''
        Python packages added to the agent's import path, for optional
        dependencies a plugin can use but the sealed venv does not ship. They
        must come from the same Python as the package (`python312Packages`).
      '';
    };

    agentPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [];
      example = lib.literalExpression "[pkgs.jq pkgs.fd]";
      description = ''
        Programs the agent can run inside the container, in addition to the
        package's own runtime tools (git, node, ripgrep, ffmpeg, ...). They
        are baked into the image and put on the container PATH.
      '';
    };

    container = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "hermes-agent";
      };

      network = lib.mkOption {
        type = with lib.types; either str (listOf str);
        default = [];
      };

      ports = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
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
    matrix.present = presence.option "the Matrix platform";
    dashboard.present = presence.option "the Hermes web dashboard, in a container of its own";
    homeassistant.present = presence.option "the Home Assistant integration, an event platform and device-control tools";
    soul.present = presence.option "the read-only SOUL.md identity file";
    agents.present = presence.option "the read-only AGENTS.md operating-instructions file";
    mcp.present = presence.option "the default MCP server set: Exa, Cloudflare, Context7 and a local mcp-nixos";
    embeddings.present = presence.option "semantic and hybrid retrieval in the LCM context engine";
    backup.present = presence.option "encrypted backups of the agent state, uploaded to Cloudflare R2";

    context-engine = lib.mkOption {
      type = lib.types.enum ["compressor" "lcm"];
      default = "compressor";
      description = "Context engine to use for conversation context management.";
    };
  };

  config.assertions =
    presence.assertions options
    (map (child: ["dotfiles" "hermes" child "present"]) [
      "signal"
      "matrix"
      "dashboard"
      "homeassistant"
      "soul"
      "agents"
      "mcp"
      "embeddings"
      "backup"
    ]);
}
