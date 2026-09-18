# pi-mcp-adapter reads ~/.config/mcp/mcp.json automatically.
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
      "pi-footer"
      "pi-lens"
      "pi-mcp-adapter"
      "pi-notify"
      "pi-plan-mode"
      "pi-pretty"
      "pi-prompt-template-model"
      "pi-service-tier"
      "pi-simplify"
      "pi-sub-core"
      "pi-subagents"
      "pi-system-theme"
      "pi-web-access"
      "rpiv-btw"
      "rpiv-todo"
    ]
    pkgs;

  # Pi discovers ~/.pi/agent/extensions/*/index.ts without a settings entry.
  localExtensions = ["quota-status" "service-tier-status"];
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

    runtimeInputs = [pkgs.jq pkgs.nodejs];

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
    defaultProvider = "openai";
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
    enabledModels = ["**/{claude-{mythos,fable,opus,sonnet,haiku},gpt}-*"];

    # pi-system-theme overrides this when the OS reports a light/dark
    # preference. This value applies if detection fails.
    theme = "catppuccin-${config.catppuccin.flavor}";

    quietStartup = true;
    collapseChangelog = true;
    enableInstallTelemetry = false;
    doubleEscapeAction = "tree";
    treeFilterMode = "default";
    autocompleteMaxVisible = 8;

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
        maxRetries = 3;
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
    };
  };

  piFooterWidget = id: type: options: {
    inherit id type options;
    enabled = true;
  };

  piFooterConfig = {
    version = 1;
    enabled = true;
    preset = "pi-footer";
    separator = "none";
    separatorFg = "default";
    separatorBg = "default";
    iconMode = "text";
    minimalist = false;
    terminal = {
      widthMode = "full";
      colorLevel = "ansi256";
    };
    lines = [
      [
        (piFooterWidget "model-provider" "model-provider" {
          raw = true;
          fg = "pi:warning";
        })
        (piFooterWidget "thinking" "thinking-level" {
          icon = " · ";
          fg = "pi:thinkingHigh";
          hideWhenEmpty = true;
        })
        (piFooterWidget "cwd" "cwd" {
          icon = " · ";
          fg = "pi:success";
          cwdDisplayStyle = "full-home";
          segments = 3;
        })
        (piFooterWidget "context-window" "context-window" {
          icon = " · ";
          fg = "pi:bashMode";
          tokenFormatStyle = "compact";
          contextConditionalColors = true;
          warningFg = "pi:warning";
          dangerFg = "pi:error";
        })
        (piFooterWidget "context-used" "context" {
          icon = " · Context ";
          fg = "pi:bashMode";
          tokenFormatStyle = "compact";
          contextConditionalColors = true;
          warningFg = "pi:warning";
          dangerFg = "pi:error";
        })
        (piFooterWidget "context-used-label" "custom-text" {
          raw = true;
          fg = "pi:bashMode";
          text = " used";
        })
      ]
      [
        (piFooterWidget "git-branch" "git-branch" {
          raw = true;
          fg = "pi:success";
          hideWhenEmpty = true;
        })
        (piFooterWidget "git-status" "git-status" {
          icon = " ";
          fg = "pi:warning";
          hideWhenEmpty = true;
        })
        (piFooterWidget "git-ahead-behind" "git-ahead-behind" {
          icon = " ";
          fg = "pi:warning";
          hideWhenEmpty = true;
        })
        (piFooterWidget "gap" "flex-separator" {})
        (piFooterWidget "quota" "event" {
          widgetId = "quota";
          icon = " ";
          fg = "pi:thinkingHigh";
          hideWhenEmpty = true;
        })
        (piFooterWidget "service-tier" "event" {
          widgetId = "service-tier";
          icon = " ";
          fg = "pi:warning";
          hideWhenEmpty = true;
        })
        (piFooterWidget "session-cost" "cost" {
          icon = " ";
          fg = "pi:bashMode";
        })
        (piFooterWidget "session-elapsed" "elapsed" {
          icon = " ";
          fg = "pi:bashMode";
        })
      ]
    ];
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

  piSystemThemeConfig = {
    darkTheme = "catppuccin-mocha";
    lightTheme = "catppuccin-latte";
    pollMs = 2000;
  };

  piWebSearchConfig.fetch = {
    answerProvider = "openai";
    answerModel = modelCatalog.openai.sol;
  };

  piSubagentsConfig = {
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

  localExtensionFiles =
    lib.listToAttrs
    (map
      (name:
        lib.nameValuePair ".pi/agent/extensions/${name}/index.ts" {
          source = ./extensions + "/${name}/index.ts";
        })
      localExtensions);
in {
  home = {
    packages = [piWithQuotaToken];

    file =
      {
        ".pi/agent/settings.json".text = toJson piSettings;
        ".pi/agent/extensions/pi-footer.json".text = toJson piFooterConfig;
        ".pi/agent/pi-sub-core-settings.json".text = toJson piSubCoreConfig;
        ".pi/agent/extensions/subagent/config.json".text = toJson piSubagentsConfig;
        ".pi/agent/system-theme.json".text = toJson piSystemThemeConfig;
        ".pi/agent/web-search.json".text = toJson piWebSearchConfig;
        ".pi/agent/AGENTS.md".text = instructions.concatenated;
      }
      // themeFiles
      // promptFiles
      // extensionFiles
      // localExtensionFiles;
  };
}
