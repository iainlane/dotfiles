let
  halls = import ../lib/halls.nix;

  # Toolsets every platform gets on top of its own preset.
  sharedToolsets = ["kanban" "context_engine"];
in {
  hostname = "ancaster";
  os = "linux";
  arch = "aarch64";
  motd = halls.ancaster;
  profiles = [
    {
      adsb = {
        secretsFile = "adsb.yaml";
      };
    }
    "base"
    "containers"
    {
      hermes = {
        profilePicture = ./ancaster/godfrey;
        signal = {
          enable = true;
          secretsFile = "ancaster/user-hermes.yaml";
        };
        matrix = {
          enable = true;
          serverName = "matrix.orangesquash.org.uk";
          username = "godfrey";
          displayName = "Godfrey";
          homeRoom = "!g6bq75R53WYYH1QJp7DUHO5wlMwYEt6TfR9tKnVRMzA";
          secretsFile = "ancaster/user-hermes.yaml";
          settings.admins_list = ["@iain:matrix.orangesquash.org.uk"];
          encryption = {
            enable = true;
            recoveryKeyKey = "matrix_recovery_key";
          };
        };
        dashboard.enable = true;
        homeassistant = {
          enable = true;
          secretsFile = "ancaster/user-hermes.yaml";
        };
        soul.enable = true;
        agents.enable = true;
        mcp.enable = true;
        context-engine = "lcm";
        # Pull in exa-py so the native web_search Exa backend has its client.
        extraDependencyGroups = ["messaging" "exa"];
        # `raft-platform` is a bundled gateway adapter we do not use; without it
        # disabled the agent probes for the absent `raft` CLI on startup.
        disabledPlugins = ["raft-platform"];
        backup = {
          enable = true;
          secretsFile = "ancaster/user-hermes.yaml";
          ageRecipient = "age18peqyehsnk772uj60e35wathys8uxh9w0v9hxt6r9k92mqqhcajslmwcpg";
        };
        secretEnvFile = "ancaster/user-hermes.yaml";
        secretEnv = {
          GROQ_API_KEY = "groq_api_key";
          OPENROUTER_API_KEY = "openrouter_api_key";
          # Exa powers web_search (native backend) and authenticates the Exa
          # MCP server, lifting it off the unauthenticated free tier.
          EXA_API_KEY = "exa_api_key";
          # Hermes' OpenAI-compatible TTS backend looks for its key under this
          # name; reuse the OpenRouter key so speech routes through OpenRouter.
          VOICE_TOOLS_OPENAI_KEY = "openrouter_api_key";
          # Anthropic via a Claude Max subscription: a long-lived Claude Code
          # OAuth token (generate with `claude setup-token`), which the
          # `anthropic` provider accepts in place of an API key.
          CLAUDE_CODE_OAUTH_TOKEN = "claude_code_oauth_token";
        };
        settings = {
          model = {
            provider = "openai-codex";
            default = "gpt-5.5";
          };
          fallback_providers = [
            {
              provider = "anthropic";
              model = "claude-opus-4-8";
            }
          ];
          memory = {
            memory_enabled = true;
            user_profile_enabled = true;
            provider = "holographic";
          };
          stt = {
            enabled = true;
            provider = "groq";
          };
          # Image generation through the existing Codex/ChatGPT subscription
          # (gpt-image-2), so it needs no separate key.
          image_gen.provider = "openai-codex";
          # Web search via Exa's neural search API.
          web.backend = "exa";
          # Text-to-speech through OpenRouter's OpenAI-compatible speech
          # endpoint, using xAI's Grok Voice TTS with the Leo voice.
          tts = {
            provider = "openai";
            openai = {
              base_url = "https://openrouter.ai/api/v1";
              model = "x-ai/grok-voice-tts-1.0";
              voice = "leo";
              speed = 1.2;
            };
          };
          # Each platform gets its own preset plus the shared toolsets, so the
          # agent can read and write its task board from either platform.
          platform_toolsets.signal = ["hermes-signal"] ++ sharedToolsets;
          platform_toolsets.matrix = ["hermes-matrix"] ++ sharedToolsets;

          cron.wrap_response = false;
          timezone = "Europe/London";
          privacy.redact_pii = true;
          security.allow_lazy_installs = false;
          approvals.mode = "smart";

          # The home room is named, so 0.17's stricter DM detection treats it
          # as a group room where the agent would otherwise stay silent until
          # @mentioned. Respond to every message instead.
          matrix.require_mention = false;

          # Codex caps gpt-5.5 at a 272K window, so compacting at the 50%
          # default wastes half of it. Set the trigger to 85% to match what
          # the agent's gpt-5.5 auto-raise would pick; once the global
          # threshold already meets that, the auto-raise is a no-op and stops
          # announcing itself each turn.
          compression.threshold = 0.85;

          gateway = {
            strict = true;
            # The workspace is the only non-default root; Hermes already allows
            # its typed media caches (image_cache, audio_cache, ...) by default.
            media_delivery_allow_dirs = ["/data/workspace"];
            trust_recent_files = true;
            trust_recent_files_seconds = 600;
          };
        };
      };
    }
    "nixbuild-substituter"
    "unifi"
  ];
}
