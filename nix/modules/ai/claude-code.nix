# Configure Claude Code: home-manager module for the package and shared MCP
# integration, plus system-level managed settings so that
# ~/.claude/settings.json can be written using `/config` etc.
_: let
  managedSettings = {
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
    voiceEnabled = true;
  };

  # Claude Code looks for managed settings at OS-specific paths:
  #   Linux: /etc/claude-code/managed-settings.json
  #   macOS: /Library/Application Support/ClaudeCode/managed-settings.json
  managedSettingsModule = {pkgs, ...}: let
    settingsFile = pkgs.writeText "claude-code-managed-settings.json" (
      builtins.toJSON managedSettings
    );
    etcPath =
      if pkgs.stdenv.hostPlatform.isDarwin
      then "Library/Application Support/ClaudeCode/managed-settings.json"
      else "claude-code/managed-settings.json";
  in {
    environment.etc.${etcPath}.source = settingsFile;
  };

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
