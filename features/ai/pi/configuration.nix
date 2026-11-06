{
  pkgs,
  accent,
  mcpServers,
  proseLintEnabled,
  temporary ? false,
  defaultModels,
  inputs,
  instructions,
  lib,
  modelCatalog,
  ...
}: let
  piExtensions =
    lib.getAttrs [
      "pi-anthropic-auth"
      "pi-ask-user"
      "pi-diff"
      "pi-prs"
      "pi-lens"
      "pi-live-models"
      "pi-notify"
      "pi-permission-auto-review"
      "pi-permission-system"
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

  catppuccin = import ./catppuccin-themes.nix {
    inherit lib;
    catppuccinPaletteSource = inputs.catppuccin-palette;
    inherit accent;
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
    defaultTools = ["+codemode" "+grep" "+find" "+ls"];
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

    # Pi includes package source paths in prompts, so keep them relative.
    packages = lib.mapAttrsToList (name: _: {source = "packages/${name}";} // lib.optionalAttrs (name == "pi-ask-user") {skills = [];}) piExtensions;

    extensions = ["managed-extensions/session-footer" "managed-extensions/planning"] ++ lib.optional proseLintEnabled "managed-extensions/prose-lint";
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
            ++ map (name: "mcp:${name}") (builtins.filter (name: builtins.hasAttr name mcpServers) ["nixos" "context7" "cloudflare-docs" "exa"]);
          subagentOnlyExtensions = ["${pkgs.pi-web-access}/${pkgs.pi-web-access.packageRoot}"];
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
    toolStyle = "claudecode";
    disableTools = ["find" "grep"];
    workingIndicator.enabled = false;
    thinkingIndicator.enabled = false;
  };

  piWebSearchConfig = {
    toolActivation = "eager";
    fetch = {
      answerProvider = "openai";
      answerModel = modelCatalog.openai.sol;
    };
  };

  planningConfig = {
    researchExtensions = map (name: "${piExtensions.${name}}/${piExtensions.${name}.packageRoot}") ["pi-lens" "pi-web-access" "rpiv-todo"];
  };

  piSubagentsConfig =
    {
      asyncWidget = false;
      asyncByDefault = false;
      forceTopLevelAsync = false;
      parallel = {
        maxTasks = 4;
        concurrency = 2;
      };
      maxSubagentDepth = 2;
      intercomBridge.mode = "off";
    }
    // lib.optionalAttrs (!temporary) {
      defaultSessionDir = "~/.pi/agent/sessions/subagent";
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

  localExtensionFiles = {
    ".pi/agent/managed-extensions/session-footer".source = "${pkgs.pi-session-footer}/${pkgs.pi-session-footer.packageRoot}";
    ".pi/agent/managed-extensions/planning".source = "${pkgs.pi-planning}/${pkgs.pi-planning.packageRoot}";
  };
in {
  xdg.configFile."rpiv-todo/config.json".text = toJson {widget.enabled = false;};
  xdg.configFile."rpiv-btw/config.json".text = toJson {crossSessionHint = false;};

  home = {
    file =
      {
        ".pi/agent/settings.json".text = toJson piSettings;
        ".pi/agent/planning.json".text = toJson planningConfig;
        ".pi/agent/ask-user.json".text = toJson {displayMode = "inline";};
        ".pi/agent/live-models.json".text = toJson piLiveModelsConfig;
        ".pi-lens/config.json".text = toJson {
          widget.visible = false;
          ui.compactLspStatus = true;
          tools.lazy = false;
          lsp.serverOverrides.typescript.command = ["${pkgs.typescript-language-server}/bin/typescript-language-server" "--stdio"];
        };
        ".pi/agent/pi-sub-core-settings.json".text = toJson piSubCoreConfig;
        ".pi/agent/extensions/subagent/config.json".text = toJson piSubagentsConfig;
        ".pi/agent/pi-pretty.json".text = toJson piPrettyConfig;
        ".pi/agent/web-search.json".text = toJson piWebSearchConfig;
        ".pi/agent/AGENTS.md".text = instructions.concatenated;
        ".pi/agent/mcp.json".text = toJson {inherit mcpServers;};
      }
      // themeFiles
      // promptFiles
      // extensionFiles
      // localExtensionFiles
      // lib.optionalAttrs proseLintEnabled {
        ".pi/agent/managed-extensions/prose-lint/index.ts".source = "${pkgs.prose-lint}/share/prose-lint/pi/index.ts";
      };
  };
}
