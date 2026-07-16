# Configure Pi (badlogic/pi-mono via numtide/llm-agents) with the shared MCP
# servers, instructions, and skills.
#
# Pi reads its config from `~/.pi/agent/`, which this module owns. Pinned
# extensions come in through `home.file` symlinks to Nix-built derivations
# (see `./extensions.nix`), so `pi update` has nothing to fetch at runtime
# and `pi-mcp-adapter` picks up `~/.config/mcp/mcp.json` (written by
# `programs.mcp`) automatically. Logging in is interactive: `/login` covers
# both ChatGPT Plus/Pro and Claude Pro/Max.
{
  pkgs,
  pkgs-unstable,
  config,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ../mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
  instructions = import ../agent-instructions.nix {inherit lib;};
  skills = import ../skills.nix {inherit lib;};
  piExtensions = import ./extensions.nix {inherit pkgs lib;};
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

  piSettings = {
    defaultProvider = "anthropic";
    defaultModel = "claude-opus-4-8";
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
      "claude-opus-*"
      "claude-sonnet-*"
      "claude-haiku-*"
      "gpt-5.6-sol"
      "gpt-5.3-codex-spark"
      "gpt-5.4-mini"
    ];

    # Resting theme that matches the system Catppuccin flavor.
    # `pi-system-theme` still overrides this when GNOME reports an
    # explicit `prefer-dark`/`prefer-light`; when GNOME reports
    # `default` (no preference), Pi stays on this value.
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
    packages = lib.mapAttrsToList (name: _: "packages/${name}") piExtensions.extensions;

    extensions = [];
    skills = ["skills"];
    prompts = ["prompts/*.md"];
    themes = ["themes/*.json"];
    enableSkillCommands = true;

    subagents = {
      disableBuiltins = false;
    };

    piClaudePermissions = {
      defaultMode = "bypassPermissions";
      allowCatastrophic = false;
      shiftTabOptions = [
        "default"
        "plan"
        "acceptEdits"
        "bypassPermissions"
      ];
    };
  };

  piKeybindings = {
    "app.thinking.cycle" = ["ctrl+shift+t"];
  };

  piFooterWidget = id: type: options: {
    inherit id type options;
    enabled = true;
  };

  # Same role assignments as `modules/ai/ccstatusline.nix`, so Pi's footer
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
    ];
  };

  # `sub-core` renders cached quota state on startup and refreshes on its
  # own timer. A short interval keeps the footer fresh, and refreshing on
  # turn start catches usage that ticked over between turns.
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

  skillFiles =
    lib.mapAttrs'
    (name: path:
      lib.nameValuePair ".pi/agent/skills/${name}" {source = path;})
    skills;

  themeFiles =
    lib.mapAttrs'
    (flavor: theme:
      lib.nameValuePair
      ".pi/agent/themes/catppuccin-${flavor}.json"
      {text = toJson theme;})
    catppuccin.themes;

  extensionFiles =
    lib.mapAttrs'
    (name: drv:
      lib.nameValuePair ".pi/agent/packages/${name}" {source = drv;})
    piExtensions.extensions;
in {
  home = {
    packages = [wrappedPi];

    file =
      {
        ".pi/agent/settings.json".text = toJson piSettings;
        ".pi/agent/keybindings.json".text = toJson piKeybindings;
        ".pi/agent/extensions/pi-footer.json".text = toJson piFooterConfig;
        ".pi/agent/pi-sub-core-settings.json".text = toJson piSubCoreConfig;
        ".pi/agent/extensions/subagent/config.json".text = toJson piSubagentsConfig;
        ".pi/agent/system-theme.json".text = toJson piSystemThemeConfig;
        ".pi/agent/AGENTS.md".text = instructions.concatenated;
      }
      // themeFiles
      // skillFiles
      // promptFiles
      // extensionFiles;
  };
}
