# Configure Claude Code: home-manager module for the package and shared MCP
# integration, plus system-level managed settings so that
# ~/.claude/settings.json can be written using `/config` etc.
_: let
  managedSettings = {ccstatuslineBin}: {
    "$schema" = "https://json.schemastore.org/claude-code-settings.json";
    alwaysThinkingEnabled = true;
    attribution = {
      commit = "";
      pr = "";
    };
    enabledPlugins = {
      "claude-code-setup@claude-plugins-official" = true;
      "claude-md-management@claude-plugins-official" = true;
      "code-review@claude-plugins-official" = true;
      "feature-dev@claude-plugins-official" = true;
      "frontend-design@claude-plugins-official" = true;
      "pr-review-toolkit@claude-plugins-official" = true;
      "ralph-loop@claude-plugins-official" = true;
      "security-guidance@claude-plugins-official" = true;
      # It seems to aggressively replace default behaviours.
      # "superpowers@claude-plugins-official" = true;
      "typescript-lsp@claude-plugins-official" = true;
    };
    env = {
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
    };
    extraKnownMarketplaces = {
      "anthropic-agent-skills" = {
        source = {
          source = "github";
          repo = "anthropics/skills";
        };
      };
    };
    model = "opus[1m]";
    skipDangerousModePermissionPrompt = true;
    statusLine = {
      type = "command";
      command = ccstatuslineBin;
      padding = 0;
    };
    voiceEnabled = true;
  };

  # Claude Code looks for managed settings at OS-specific paths:
  #   Linux: /etc/claude-code/managed-settings.json
  #   macOS: /Library/Application Support/ClaudeCode/managed-settings.json
  #
  # On Linux, `environment.etc` maps directly to /etc which is the right
  # location. On macOS the target is /Library (not /etc), so we symlink the
  # store path into place via an activation script — the same mechanism that
  # `environment.etc` itself uses under the hood.
  managedSettingsModule = {
    lib,
    pkgs,
    inputs,
    ...
  }: let
    inherit (pkgs.stdenv.hostPlatform) system isDarwin;
    inherit (inputs.llm-agents.packages.${system}) ccstatusline;
    settings = managedSettings {
      ccstatuslineBin = "${ccstatusline}/bin/ccstatusline";
    };
    settingsFile =
      (pkgs.formats.json {}).generate "managed-settings.json" settings;

    darwinPath = "/Library/Application Support/ClaudeCode";
  in
    lib.mkMerge [
      (lib.mkIf (!isDarwin) {
        environment.etc."claude-code/managed-settings.json".source = settingsFile;
      })
      (lib.mkIf isDarwin {
        system.activationScripts.postActivation.text = ''
          mkdir -p '${darwinPath}'
          ln -sf '${settingsFile}' '${darwinPath}/managed-settings.json'
        '';
      })
    ];

  homeManagerModule = {
    pkgs,
    inputs,
    lib,
    system,
    ...
  }: let
    mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};
    instructions = import ./agent-instructions.nix {inherit lib;};

    wrappedClaudeCode = mcp.wrapWithTools {
      package = inputs.llm-agents.packages.${system}.claude-code;
      binName = "claude";
    };
  in {
    programs.claude-code = {
      enable = true;
      package = wrappedClaudeCode;

      # Pull MCP servers from the shared programs.mcp config.
      enableMcpIntegration = true;

      # Shared instructions as auto-loaded rule files.
      rules = instructions.files;
    };

    xdg.configFile."ccstatusline/settings.json".source = pkgs.writeText "ccstatusline-settings.json" (builtins.toJSON (
      import ./ccstatusline.nix
    ));
  };
in {
  flake.modules.ai = {
    homeManagerModules = [homeManagerModule];
    # Managed settings are picked up by both nix-darwin / system-manager
    # (systemManagerModules) and NixOS (nixosModules).
    systemManagerModules = [managedSettingsModule];
    nixosModules = [managedSettingsModule];
  };
}
