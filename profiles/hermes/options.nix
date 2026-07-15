{lib, ...}: {
  options.services.hermes-agent = {
    enable = lib.mkEnableOption "Hermes Agent gateway service";

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

    matrix = {
      enable = lib.mkEnableOption "the Matrix platform, backed by a Continuwuity homeserver sidecar";

      serverName = lib.mkOption {
        type = lib.types.str;
        example = "matrix.orangesquash.org.uk";
        description = ''
          The homeserver's `server_name`: the domain suffix of every user and
          room ID (`@hermes:<serverName>`). It is baked into all identifiers and
          cannot be changed once accounts and rooms exist, so choose carefully.
          It need not be the address clients connect to; with federation off it
          is purely an identity label.
        '';
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = "hermes";
        description = ''
          Local part of the bot's Matrix user ID; the full ID is
          `@<username>:<serverName>`. The bootstrap step creates this account
          and the agent logs in as it.
        '';
      };

      displayName = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        example = "Godfrey";
        description = ''
          Display name set on the bot's Matrix profile. Null leaves whatever the
          account already has (the lowercase local part from account creation).
        '';
      };

      homeRoom = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "!abcdef:matrix.orangesquash.org.uk";
        description = ''
          Optional room ID for cron and notification delivery. Left empty the
          bot still works in DMs and threads; set it once you have a room you
          want unsolicited output to land in.
        '';
      };

      secretsFile = lib.mkOption {
        type = lib.types.str;
        example = "ancaster/user-hermes.yaml";
        description = ''
          Path, relative to the `secrets` flake input, of the sops file holding
          `matrix_password` (the bot account's password, which the homeserver
          creates the account with and the agent logs in with),
          `matrix_allowed_users` (comma-separated user IDs allowed to talk to
          the bot) and `matrix_registration_token` (the token that gates
          registration, entered in a Matrix client to create accounts).
        '';
      };

      encryption = {
        enable = lib.mkEnableOption "end-to-end encryption for the bot's Matrix account";

        deviceId = lib.mkOption {
          type = lib.types.str;
          default = "hermes-agent";
          description = ''
            Fixed device ID for the bot, so the same device (and its E2EE keys)
            is reused on every login and persists across restarts.
          '';
        };

        recoveryKeyKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "matrix_recovery_key";
          description = ''
            Key in `secretsFile` holding the cross-signing recovery key. Leave
            null on the first encrypted run: the bot bootstraps cross-signing
            and logs a fresh recovery key. Save that into the secrets file and
            set this so the bot re-signs its device after key rotation on later
            restarts.
          '';
        };
      };

      provisionUsers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            passwordKey = lib.mkOption {
              type = lib.types.str;
              description = ''
                Key in `secretsFile` holding this account's password. The
                password must not contain whitespace, `"` or `\` (it travels
                through a TOML string and a whitespace-split admin command);
                anything else, such as the output of `openssl rand -base64 24`,
                is fine.
              '';
            };

            admin = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Grant this account server-admin rights, needed to run `!admin`
                commands (such as creating further users) from a Matrix client.
              '';
            };
          };
        });
        default = {};
        example = lib.literalExpression ''{ iain = { passwordKey = "matrix_iain_password"; admin = true; }; }'';
        description = ''
          Extra accounts the homeserver creates at startup via its admin
          command, keyed by local username (`@<name>:<serverName>`). The bot's
          own account is always created; these are additional accounts, such as
          your own. Each `passwordKey` must exist in `secretsFile`.
        '';
      };

      httpUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://matrix:6167";
        description = ''
          URL at which Hermes reaches the homeserver's client-server API. The
          default resolves the Continuwuity container by name over the shared
          podman network.
        '';
      };

      network = lib.mkOption {
        type = lib.types.str;
        default = "matrixnet";
        description = "Podman network shared between Hermes and the Continuwuity homeserver.";
      };

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Continuwuity package to run. Defaults to `pkgs.matrix-continuwuity`.";
      };

      containerName = lib.mkOption {
        type = lib.types.str;
        default = "matrix";
        description = "Name of the Continuwuity podman container, and the host it is reached at on the network.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 6167;
        description = "Port the homeserver's client-server API listens on, inside the container and as published on `listenAddress`.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          Host address the client-server API is published on, for a reverse
          proxy to front. Defaults to localhost so it stays off any routable
          interface; put your own proxy (for example `tailscale serve`) in
          front of it to reach it with a Matrix client.
        '';
      };

      settings = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = ''
          Extra Continuwuity `[global]` settings, merged over the defaults this
          module sets (`server_name`, listen address and port, federation off,
          token-gated registration). See https://continuwuity.org/configuration.html.
        '';
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
          Loopback address the dashboard binds to, on the host network
          namespace. Keep it on loopback: Hermes engages its own auth gate on
          any non-loopback bind and refuses to start without an auth provider.
          Put a reverse proxy (for example `tailscale serve`) in front to
          expose it.
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

    agents = {
      enable = lib.mkEnableOption "installing a read-only AGENTS.md operating-instructions file";

      file = lib.mkOption {
        type = lib.types.path;
        default = ./agents.md;
        description = ''
          Markdown file installed as AGENTS.md in the agent's working
          directory, loaded as workspace context alongside SOUL.md.
        '';
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
