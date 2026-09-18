# Configure Pi (badlogic/pi-mono via numtide/llm-agents) with the shared MCP
# servers, instructions, and skills.
#
# Pi reads its config from `~/.pi/agent/`, which this module owns. Published
# extensions are packaged under `pkgs/` and come in through `home.file`
# symlinks, so `pi update` has nothing to fetch at runtime, and the few written
# here live in `./extensions/`. `pi-mcp-adapter` picks up
# `~/.config/mcp/mcp.json` (written by `programs.mcp`) automatically. Logging in
# is interactive: `/login` covers both ChatGPT Plus/Pro and Claude Pro/Max.
{
  pkgs,
  config,
  defaultModels,
  inputs,
  instructions,
  lib,
  mcp,
  system,
  ...
}: let
  # The extensions to install, each packaged under `pkgs/<name>/` and bumped by
  # `nix run .#update-<name>`.
  piExtensions =
    lib.getAttrs [
      "pi-footer"
      "pi-lens"
      "pi-mcp-adapter"
      "pi-notify"
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

  # Extensions written here, kept in `./extensions/`. Pi discovers
  # `~/.pi/agent/extensions/*/index.ts` on its own, so these need no setting.
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

  # Anthropic serves the subscription quota windows from an endpoint that only
  # accepts an OAuth token, so an API key cannot read them and `pi-sub-core`
  # shows nothing. Claude Code stores a token with the scope that endpoint
  # wants, so hand Pi a copy when one is there to read.
  piWithQuotaToken = pkgs.writeShellApplication {
    name = "pi";

    runtimeInputs = [pkgs.jq];

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
    enabledModels = [
      "claude-mythos-*"
      "claude-fable-*"
      "claude-opus-*"
      "claude-sonnet-*"
      "claude-haiku-*"
      "gpt-*"
    ];

    # Resting theme, matching the system Catppuccin flavour. `pi-system-theme`
    # overrides it whenever the desktop reports light or dark, reading
    # `AppleInterfaceStyle` on macOS and `color-scheme` on GNOME. Pi keeps this
    # value when neither reports a preference, and when detection fails.
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
    npmCommand = ["nix" "shell" "nixpkgs#nodejs" "-c" "npm"];

    # Point Pi at stable symlinks in ~/.pi/agent/packages. Home Manager keeps
    # those symlinks rooted in the current generation, while the settings file
    # stays readable and avoids leaking long store paths into the prompt.
    packages = lib.mapAttrsToList (name: _: "packages/${name}") piExtensions;

    extensions = [];
    prompts = ["prompts/*.md"];
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

  # Same role assignments as `features/ai/claude-code/ccstatusline`, so Pi's footer
  # reads like Claude Code's statusline at a glance.
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
      # Second line, matching what ccstatusline shows for Claude Code: where
      # the working tree stands on the left, and what the session is costing
      # on the right.
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
        # Published by `./extensions/quota-status` from pi-sub-core's data.
        (piFooterWidget "quota" "event" {
          widgetId = "quota";
          icon = " ";
          fg = "pi:thinkingHigh";
          hideWhenEmpty = true;
        })
        # Published by `./extensions/service-tier-status` from pi-service-tier.
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

  # pi-sub-core publishes cached quota state and refreshes it on its own
  # timer. The quota-status extension displays that state through pi-footer.
  piSubCoreConfig = {
    version = 3;
    behavior = {
      refreshInterval = 5;
      minRefreshInterval = 5;
      refreshOnTurnStart = true;
      refreshOnToolResult = false;
    };
  };

  # `pi-system-theme` reads this file (or `/system-theme` writes to it).
  # Mapping both modes to Catppuccin keeps the same visual identity across
  # light and dark, just with the matching palette.
  piSystemThemeConfig = {
    darkTheme = "catppuccin-mocha";
    lightTheme = "catppuccin-latte";
    pollMs = 2000;
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
  promptFiles =
    lib.mapAttrs'
    (name: _:
      lib.nameValuePair ".pi/agent/prompts/${name}" {
        source = promptDir + "/${name}";
      })
    (lib.filterAttrs
      (name: type: type == "regular" && lib.hasSuffix ".md" name)
      (builtins.readDir promptDir));

  themeFiles =
    lib.mapAttrs'
    (flavor: theme:
      lib.nameValuePair
      ".pi/agent/themes/catppuccin-${flavor}.json"
      {text = toJson theme;})
    catppuccin.themes;

  # Each extension is installed as an npm package, so the directory Pi loads
  # is the one that contains its `package.json`, not the derivation root.
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
        ".pi/agent/AGENTS.md".text = instructions.concatenated;
      }
      // themeFiles
      // promptFiles
      // extensionFiles
      // localExtensionFiles;
  };
}
