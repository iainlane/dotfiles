{lib, ...}: {
  options.services.hermes-agent = {
    enable = lib.mkEnableOption "Hermes Agent gateway service";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
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
      type = with lib.types; listOf str;
      default = ["curl" "wget"];
      example = ["curl" "wget" "jq" "fd"];
      description = ''
        Programs, by nixpkgs attribute name, that the agent can run inside the
        container — in addition to the package's own runtime tools (git, node,
        ripgrep, ffmpeg, ...). They are baked into the image and put on the
        container PATH so they resolve by name.
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
        type = with lib.types; listOf str;
        default = [];
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

    signal = {
      enable = lib.mkEnableOption "the Signal platform, backed by a signal-cli daemon sidecar";

      secretsFile = lib.mkOption {
        type = lib.types.str;
        example = "ancaster/user-hermes.yaml";
        description = ''
          Path, relative to the `secrets` flake input, of the sops file
          holding `signal_account`, `signal_allowed_users` and
          `signal_home_channel`.
        '';
      };

      httpUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://signal-cli:8080";
        description = "URL at which Hermes reaches the signal-cli daemon.";
      };

      network = lib.mkOption {
        type = lib.types.str;
        default = "hermesnet";
        description = "Podman network shared between Hermes and signal-cli.";
      };

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "signal-cli package to run. Defaults to `pkgs.signal-cli`.";
      };

      containerName = lib.mkOption {
        type = lib.types.str;
        default = "signal-cli";
        description = "Name of the signal-cli podman container.";
      };
    };

    dashboard = {
      enable = lib.mkEnableOption "the Hermes web dashboard, in a separate container";

      port = lib.mkOption {
        type = lib.types.port;
        default = 9119;
        description = "Port the dashboard listens on.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          Host address the dashboard is published on. Defaults to localhost so
          it stays unexposed; put a reverse proxy (for example `tailscale
          serve`) in front of it to expose it. The dashboard manages
          credentials, so do not bind it to a routable address directly.
        '';
      };

      containerName = lib.mkOption {
        type = lib.types.str;
        default = "hermes-dashboard";
        description = "Name of the dashboard podman container.";
      };
    };

    homeassistant = {
      enable = lib.mkEnableOption "the Home Assistant integration (event platform plus device-control tools)";

      secretsFile = lib.mkOption {
        type = lib.types.str;
        example = "ancaster/user-hermes.yaml";
        description = ''
          Path, relative to the `secrets` flake input, of the sops file holding
          `hass_token` (a Home Assistant long-lived access token) and `hass_url`
          (the Home Assistant base URL, e.g. `http://homeassistant.local:8123`).
        '';
      };
    };

    soul = {
      enable = lib.mkEnableOption "installing a read-only SOUL.md identity file";

      file = lib.mkOption {
        type = lib.types.path;
        default = ./soul.md;
        description = "Markdown file installed as the agent's SOUL.md identity.";
      };
    };

    mcp = {
      enable = lib.mkEnableOption "the default MCP server set (exa, context7, nixos, cloudflare)";
    };

    context-engine = lib.mkOption {
      type = lib.types.enum ["compressor" "lcm"];
      default = "compressor";
      description = "Context engine to use for conversation context management.";
    };

    backup = {
      enable = lib.mkEnableOption "scheduled, encrypted backups of the Hermes state to Cloudflare R2";

      secretsFile = lib.mkOption {
        type = lib.types.str;
        example = "ancaster/user-hermes.yaml";
        description = ''
          Path, relative to the `secrets` input, of the sops file holding
          `r2_bucket`, `r2_endpoint`, `r2_access_key_id`, and
          `r2_secret_access_key`.
        '';
      };

      ageRecipient = lib.mkOption {
        type = lib.types.str;
        example = "age1qz...";
        description = ''
          age public key the backup is encrypted to. Keep the matching private
          key offline; it is needed to restore.
        '';
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 04:00:00";
        description = "systemd `OnCalendar` schedule for the backup.";
      };

      keepDays = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = "Delete remote backups older than this many days.";
      };

      prefix = lib.mkOption {
        type = lib.types.str;
        default = "hermes";
        description = "Path prefix within the R2 bucket.";
      };
    };
  };
}
