{
  pkgs,
  config,
  defaultModels,
  inputs,
  instructions,
  lib,
  mcp,
  modelCatalog,
  system,
  ...
}: let
  piExtensions =
    lib.getAttrs [
      "pi-anthropic-auth"
      "pi-diff"
      "pi-prs"
      "pi-lens"
      "pi-live-models"
      "pi-notify"
      "pi-plan-mode"
      "pi-pretty"
      "pi-prompt-template-model"
      "pi-service-tier"
      "pi-simplify"
      "pi-sub-core"
      "pi-subagents"
      "pi-web-access"
      "rpiv-btw"
      "rpiv-todo"
    ]
    pkgs;

  # Pi discovers ~/.pi/agent/extensions/*/index.ts without a settings entry.
  sessionFooter = import ./session-footer-package.nix {inherit pkgs;};
  catppuccin = import ./catppuccin-themes.nix {
    inherit lib;
    catppuccinPaletteSource = inputs.catppuccin-palette;
    inherit (config.catppuccin) accent;
  };

  wrappedPi = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.pi;
    binName = "pi";
    extraWrapperArgs = [
      "--set"
      "PI_SKIP_VERSION_CHECK"
      "1"
      "--set"
      "PI_TELEMETRY"
      "0"
    ];
  };

  # Anthropic's quota endpoint requires an OAuth token with user:profile;
  # API keys cannot query it. Claude Code stores a token with that scope.
  piWithQuotaToken = pkgs.writeShellApplication {
    name = "pi";

    runtimeInputs = [pkgs.jq pkgs.nodejs pkgs.gh];

    text = ''
      credentials="''${CLAUDE_CONFIG_DIR:-''${HOME}/.claude}/.credentials.json"

      if [[ -z "''${ANTHROPIC_OAUTH_TOKEN:-}" && -r "''${credentials}" ]]; then
        token="$(jq --raw-output '
          .claudeAiOauth
          | select((.scopes // []) | index("user:profile"))
          | .accessToken // empty
        ' "''${credentials}" 2>/dev/null || true)"

        if [[ -n "''${token}" ]]; then
          export ANTHROPIC_OAUTH_TOKEN="''${token}"
        fi
      fi

      exec ${lib.getExe wrappedPi} "$@"
    '';
  };

  piSettings = {
    defaultProvider = "openai-codex";
    defaultModel = defaultModels.openai;
    defaultThinkingLevel = "high";
    thinkingBudgets = {
      minimal = 1024;
      low = 4096;
      medium = 10240;
      high = 32768;
      xhigh = 64000;
    };
    hideThinkingBlock = true;

    theme = "catppuccin-latte/catppuccin-mocha";

    quietStartup = "header";
    collapseChangelog = true;
    enableInstallTelemetry = false;
    doubleEscapeAction = "tree";
    treeFilterMode = "default";
    autocompleteMaxVisible = 8;
    defaultTools = ["+codemode"];
    codemode.mode = "on";

    compaction = {
      enabled = true;
      reserveTokens = 16384;
      keepRecentTokens = 20000;
    };
    retry = {
      enabled = true;
      maxRetries = 5;
      baseDelayMs = 3000;
      provider = {
        maxRetries = 0;
        maxRetryDelayMs = 120000;
      };
    };
    markdown.codeBlockIndent = " ";
    warnings.anthropicExtraUsage = false;

    # Stable symlinks keep store paths out of prompts. Home Manager retains
    # their targets in the active generation.
    packages = lib.mapAttrsToList (name: _: "packages/${name}") piExtensions;

    extensions = [];
    themes = ["themes/*.json"];
    enableSkillCommands = true;

    subagents = {
      disableBuiltins = false;
      agentOverrides = {
        reviewer = {
          thinking = "high";
          tools = ["read" "grep" "find" "ls" "watchdog_diff" "contact_supervisor"];
        };
        researcher = {
          thinking = "medium";
          tools =
            ["read" "write" "web_search" "fetch_content" "get_search_content" "source_check" "codemode"]
            ++ map (name: "mcp:${name}") (builtins.filter (name: builtins.hasAttr name config.dotfiles.ai.mcpServers) ["nixos" "context7" "cloudflare-docs" "exa"]);
          subagentOnlyExtensions = ["~/.pi/agent/packages/pi-web-access"];
        };
      };
      agentOverridesByProvider.openai-codex = {
        reviewer.model = "openai-codex/${modelCatalog.openai.sol}";
        researcher.model = "openai-codex/${modelCatalog.openai.sol}";
      };
    };
  };

  piLiveModelsConfig.providers.openrouter = {
    baseUrl = "https://openrouter.ai/api/v1";
    api = "openai-completions";
    catalog = false;
    costFromLive = "always";
    mergeStatic = "union";
    overrides."deepseek/deepseek-v4.1-flash-1017" = {
      reasoning = true;
      input = ["text" "image"];
      thinkingLevelMap = {
        off = "none";
        minimal = null;
        low = "low";
        medium = null;
        high = "high";
        xhigh = null;
        max = "max";
      };
      compat = {
        supportsDeveloperRole = false;
        thinkingFormat = "openrouter";
        supportsStrictMode = true;
        sendSessionAffinityHeaders = true;
        requiresReasoningContentOnAssistantMessages = true;
      };
    };
  };

  piSubCoreConfig = {
    version = 3;
    behavior = {
      refreshInterval = 5;
      minRefreshInterval = 5;
      refreshOnTurnStart = true;
      refreshOnToolResult = false;
    };
  };

  piPrettyConfig = {
    workingIndicator.enabled = false;
    thinkingIndicator.enabled = false;
  };

  piWebSearchConfig.fetch = {
    answerProvider = "openai";
    answerModel = modelCatalog.openai.sol;
  };

  piSubagentsConfig = {
    asyncWidget = false;
    asyncByDefault = false;
    forceTopLevelAsync = false;
    parallel = {
      maxTasks = 4;
      concurrency = 2;
    };
    defaultSessionDir = "~/.pi/agent/sessions/subagent";
    maxSubagentDepth = 1;
    intercomBridge.mode = "off";
  };

  toJson = builtins.toJSON;

  promptDir = ./prompts;
  promptModels.sol = "${modelCatalog.openai.sol}, openrouter/${modelCatalog.openrouter.sol}";
  renderPrompt = prompt:
    lib.concatStringsSep "\n" [
      "---"
      (lib.generators.toYAML {} (removeAttrs prompt ["body"]))
      "---"
      ""
      prompt.body
    ];

  # Pi scans only the top level, while pi-prompt-template-model recurses.
  # A subdirectory prevents Pi from registering a second command.
  promptFiles =
    lib.mapAttrs'
    (name: _: let
      promptName = lib.removeSuffix ".nix" name;
    in
      lib.nameValuePair ".pi/agent/prompts/${promptName}/${promptName}.md" {
        text = renderPrompt (import (promptDir + "/${name}") {models = promptModels;});
      })
    (lib.filterAttrs
      (name: type: type == "regular" && lib.hasSuffix ".nix" name)
      (builtins.readDir promptDir));

  themeFiles =
    lib.mapAttrs'
    (flavor: theme:
      lib.nameValuePair
      ".pi/agent/themes/catppuccin-${flavor}.json"
      {text = toJson theme;})
    catppuccin.themes;

  # Pi needs the directory containing package.json, not the derivation root.
  extensionFiles =
    lib.mapAttrs'
    (name: drv:
      lib.nameValuePair ".pi/agent/packages/${name}" {
        source = "${drv}/${drv.packageRoot}";
      })
    piExtensions;

  localExtensionFiles.".pi/agent/extensions/session-footer".source = sessionFooter;
in {
  xdg.configFile."rpiv-todo/config.json".text = toJson {widget.enabled = false;};

  home = {
    packages = [piWithQuotaToken];

    file =
      {
        ".pi/agent/settings.json".text = toJson piSettings;
        ".pi/agent/live-models.json".text = toJson piLiveModelsConfig;
        ".pi-lens/config.json".text = toJson {
          widget.visible = false;
          ui.compactLspStatus = true;
        };
        ".pi/agent/pi-sub-core-settings.json".text = toJson piSubCoreConfig;
        ".pi/agent/extensions/subagent/config.json".text = toJson piSubagentsConfig;
        ".pi/agent/pi-pretty.json".text = toJson piPrettyConfig;
        ".pi/agent/web-search.json".text = toJson piWebSearchConfig;
        ".pi/agent/AGENTS.md".text = instructions.concatenated;
        ".pi/agent/mcp.json".text = toJson {mcpServers = config.dotfiles.ai.mcpServers;};
      }
      // themeFiles
      // promptFiles
      // extensionFiles
      // localExtensionFiles
      // lib.optionalAttrs config.dotfiles.ai.proseLint.enable {
        ".pi/agent/extensions/prose-lint/index.ts".source = "${pkgs.prose-lint}/share/prose-lint/pi/index.ts";
      };
  };
}
