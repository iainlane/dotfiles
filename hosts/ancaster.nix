{config, ...}: let
  inherit (config.flake) features;
  halls = import ../lib/halls.nix;

  # Toolsets every platform gets on top of its own preset.
  sharedToolsets = ["kanban" "context_engine"];
in {
  flake.agentsviewServer.domain = "agentsdb.orangesquash.org.uk";

  flake.hosts.ancaster = {
    os = "generic-linux";
    arch = "aarch64";
    motd = halls.ancaster;
    features = [
      features.adsb
      features.agentsview
      features.agentsview-server
      features.base
      features.containers
      features.dex
      features.matrix
      features.hermes
      features.network
      features.nixbuild-substituter
      features.unifi
      features.caddy
    ];

    systemModule = {
      dotfiles = {
        network.systemd.network.networks."10-eth0" = {
          matchConfig.Name = "eth0";
          address = [
            "192.168.1.138/24"
            # Routed to this host by the ISP. The proxy publishes its ports on
            # it, and it is a /32 because nothing else on the LAN holds one.
            "81.187.184.100/32"
            # One address out of the /64 routed here. The rest of the prefix is
            # delegated to the proxy's own podman network.
            "2001:8b0:df29:1a0::/128"
          ];
          networkConfig = {
            Gateway = "192.168.1.100";
            MulticastDNS = "yes";
          };
          linkConfig.RequiredForOnline = "yes";
        };

        adsb = {
          secretsFile = "adsb.yaml";
          expose.domain = "adsb.orangesquash.org.uk";
          piaware.expose.domain = "piaware.orangesquash.org.uk";
          fr24.expose.domain = "fr24.orangesquash.org.uk";
        };

        agentsviewServer.expose = {
          domain = "agents.orangesquash.org.uk";
          auth = true;
        };

        dex.expose = {
          domain = "auth.orangesquash.org.uk";
          auth = false;
        };

        matrix = {
          serverName = "orangesquash.org.uk";
          botUsername = "godfrey";
          users.iain = {
            admin = true;
            supportUser = true;
          };
          expose = {
            domain = "matrix.orangesquash.org.uk";
            auth = false;
          };
        };

        hermes = {
          profilePicture = ./ancaster/godfrey;
          matrix = {
            serverName = "orangesquash.org.uk";
            httpUrl = "https://matrix.orangesquash.org.uk";
            username = "godfrey";
            displayName = "Godfrey";
            encryption = true;
          };
          dashboard.expose = {
            domain = "godfrey.orangesquash.org.uk";
            auth = true;
          };
          context-engine = "lcm";
          embeddings = {
            # OpenRouter serves OpenAI-shaped embeddings, so LCM reaches it
            # through the provider proposed in hermes-lcm#519 and reads the key
            # from the variable `secretEnv` already sets for the agent's models.
            baseUrl = "https://openrouter.ai/api/v1";
            apiKeyVariable = "OPENROUTER_API_KEY";
            # 1024-dim and multilingual, at $0.01 per million input tokens.
            model = "baai/bge-m3";
          };
          # Pull in exa-py so the native web_search Exa backend has its client.
          extraDependencyGroups = ["exa"];
          # `raft-platform` is a bundled gateway adapter we do not use; without it
          # disabled the agent probes for the absent `raft` CLI on startup.
          # `google_chat-platform` registers a Platform value the gateway does
          # not define, so it fails to load and warns on every startup.
          disabledPlugins = ["raft-platform" "google_chat-platform"];
          secretEnvFile = "ancaster/host-hermes.yaml";
          secretEnv = {
            GROQ_API_KEY = "groq_api_key";
            OPENROUTER_API_KEY = "openrouter_api_key";
            # Exa powers web_search (native backend) and authenticates the Exa
            # MCP server, lifting it off the unauthenticated free tier.
            EXA_API_KEY = "exa_api_key";
            # Hermes' OpenAI-compatible TTS backend looks for its key under this
            # name; reuse the OpenRouter key so speech routes through OpenRouter.
            VOICE_TOOLS_OPENAI_KEY = "openrouter_api_key";
          };
          settings = {
            model = {
              provider = "openai-codex";
            };
            agent.reasoning_effort = "high";
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

            compression.threshold = 0.85;

            # Keep memory updates silent in chat; the background review still runs.
            display.memory_notifications = "off";

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

        caddy = {
          # The spare address routed here, not the one the LAN answers on.
          ipv4Address = "81.187.184.100";
          # Delegated from the /64 routed to this host, so the proxy is reached
          # over IPv6 without publishing or translation.
          network.v6 = {
            subnet = "2001:8b0:df29:1a0:c::/80";
            # Named at the far end of the range, leaving the low addresses for
            # the services. Left unset, the bridge would take `::1`.
            gateway = "2001:8b0:df29:1a0:c::ffff";
            # Keeps the low addresses free for the services given a fixed one,
            # `ipv6Address` below among them.
            range = "2001:8b0:df29:1a0:c::100/120";
          };
          ipv6Address = "2001:8b0:df29:1a0:c::1";
          email = "iain@orangesquash.org.uk";
          # The LAN and the IoT VLAN reach these addresses directly, so they
          # hold no certificate from Cloudflare to present.
          originAuth.directSources = [
            "192.168.1.0/24"
            "192.168.2.0/24"
            "2001:8b0:df29::/48"
          ];
          auth = {
            cookieDomain = ".orangesquash.org.uk";
            secretsFile = "ancaster/host-oauth2-proxy.yaml";
            allow = ["iainlane"];
          };
        };
      };
    };
  };
}
