{config, ...}: let
  inherit (config.flake) features halls;

  # The toolsets that every platform gets on top of its own preset.
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
      features.agentsview.provides.embeddings
      features.agentsview-server
      features.base
      features.containers
      features.dex
      features.matrix
      features.hermes
      features.hermes.provides.agentsview
      features.hermes.provides.identity
      features.hermes.provides.inbox
      features.hermes.provides.webhook
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
            # A second address that the ISP routes to this host; the proxy
            # publishes its ports on it. A /32, because it is routed here and
            # shares no subnet with the LAN.
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

        # ancaster uses ethernet only.
        network.systemd.network.networks."10-wlan0" = {
          matchConfig.Name = "wlan0";
          linkConfig.ActivationPolicy = "down";
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
          identity = {
            name = "Godfrey";
            email = "godfrey@orangesquash.org.uk";
          };
          inbox = {
            matrixRoomId = "!woL3cp6c1ydExPf6Uqk2sTMmksH5g9t5vBGCZq4IXQY";
            matrixUserId = "@iain:orangesquash.org.uk";
          };
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
          webhook.expose = {
            domain = "hooks.godfrey.orangesquash.org.uk";
            auth = false;
          };
          contextEngine = "lcm";
          embeddings = {
            # OpenRouter's embeddings endpoint is OpenAI-compatible. `secretEnv`
            # already provides OPENROUTER_API_KEY for the agent's models, so the
            # embedding provider reads the same variable.
            baseUrl = "https://openrouter.ai/api/v1";
            apiKeyVariable = "OPENROUTER_API_KEY";
            model = "baai/bge-m3";
          };
          extraDependencyGroups = ["exa"];
          secretEnvFile = "ancaster/host-hermes.yaml";
          secretEnv = {
            GROQ_API_KEY = "groq_api_key";
            OPENROUTER_API_KEY = "openrouter_api_key";
            EXA_API_KEY = "exa_api_key";
            # Hermes' OpenAI-compatible speech backend reads its key from this
            # variable, so the OpenRouter key sends speech through OpenRouter.
            VOICE_TOOLS_OPENAI_KEY = "openrouter_api_key";
          };
          mcp.tokens = {
            browser-rendering = "cloudflare_browser_token";
            exa = "exa_api_key";
          };
          settings = {
            # `raft-platform` is a bundled gateway adapter that this host does not
            # use. While it is enabled the agent probes for the absent `raft`
            # CLI at startup. `google_chat-platform` needs the `google-chat`
            # dependency group, which the `all` group no longer includes.
            plugins.disabled = ["raft-platform" "google_chat-platform" "spotify" "a2a-platform"];

            agent.disabled_toolsets = ["computer_use" "browser-cdp"];

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
            # Image generation runs through the Codex OAuth session, so it
            # needs no OpenAI key.
            image_gen.provider = "openai-codex";
            web.backend = "exa";
            tts = {
              provider = "openai";
              openai = {
                base_url = "https://openrouter.ai/api/v1";
                model = "x-ai/grok-voice-tts-1.0";
                voice = "leo";
                speed = 1.2;
              };
            };
            # Each entry replaces the platform's whole toolset list, so the
            # platform's own toolset has to be listed alongside the shared
            # ones.
            platform_toolsets.signal = ["hermes-signal"] ++ sharedToolsets;
            platform_toolsets.matrix = ["hermes-matrix"] ++ sharedToolsets;

            cron.wrap_response = false;
            timezone = "Europe/London";
            privacy.redact_pii = true;
            security.allow_lazy_installs = false;
            approvals.mode = "smart";

            # The default makes the agent ignore a message in a group room
            # unless the message @mentions it.
            matrix.require_mention = false;

            compression.threshold = 0.85;

            # Keep memory updates silent in chat; the background review still runs.
            display.memory_notifications = "off";

            gateway = {
              strict = true;
              # Hermes always trusts its own media cache, so only the workspace
              # has to be listed here.
              media_delivery_allow_dirs = ["/data/workspace"];
              trust_recent_files = true;
              trust_recent_files_seconds = 600;
            };
          };
        };

        caddy = {
          ipv4Address = "81.187.184.100";
          network.v6 = {
            subnet = "2001:8b0:df29:1a0:c::/80";
            # Without this, netavark gives the bridge the first address in
            # the subnet, which is the address that `ipv6Address` takes.
            gateway = "2001:8b0:df29:1a0:c::ffff";
            range = "2001:8b0:df29:1a0:c::100/120";
          };
          ipv6Address = "2001:8b0:df29:1a0:c::1";
          email = "iain@orangesquash.org.uk";
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
