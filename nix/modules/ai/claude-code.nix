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
    tui = "fullscreen";
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

  # Build the generated JSON derivation from the current `pkgs`/`inputs`.
  mkSettingsFile = {
    pkgs,
    inputs,
  }: let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (inputs.llm-agents.packages.${system}) ccstatusline;
    settings = managedSettings {
      ccstatuslineBin = "${ccstatusline}/bin/ccstatusline";
    };
  in
    (pkgs.formats.json {}).generate "managed-settings.json" settings;

  # Linux/NixOS: write via environment.etc. Both NixOS and
  # system-manager-linux expose environment.etc.
  linuxManagedSettingsModule = {
    pkgs,
    inputs,
    ...
  }: {
    environment.etc."claude-code/managed-settings.json".source =
      mkSettingsFile {inherit pkgs inputs;};
  };

  # Darwin: symlink the generated file from /Library. nix-darwin exposes
  # `system.activationScripts.postActivation` for this; system-manager
  # (linux) does not, which is why this module is gated to darwin only.
  darwinManagedSettingsModule = {
    pkgs,
    inputs,
    ...
  }: let
    settingsFile = mkSettingsFile {inherit pkgs inputs;};
    darwinPath = "/Library/Application Support/ClaudeCode";
  in {
    system.activationScripts.postActivation.text = ''
      mkdir -p '${darwinPath}'
      ln -sf '${settingsFile}' '${darwinPath}/managed-settings.json'
    '';
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
    skills = import ./skills.nix {inherit lib;};

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

      # Shared skills from ./skills/.
      inherit skills;
    };

    xdg.configFile."ccstatusline/settings.json".source = pkgs.writeText "ccstatusline-settings.json" (builtins.toJSON (
      import ./ccstatusline.nix
    ));
  };
in {
  flake.modules.ai = {
    homeManagerModules = [homeManagerModule];
    # Managed settings file is placed per-OS. Linux (both NixOS and
    # system-manager) uses environment.etc; darwin uses an activation-script
    # symlink into /Library. Splitting the two avoids feeding the darwin
    # branch to system-manager-linux, whose `system.activationScripts` is
    # narrower than nix-darwin's and rejects the definition even under
    # `lib.mkIf false`.
    nixosModules = [linuxManagedSettingsModule];
    os.linux.systemManagerModules = [linuxManagedSettingsModule];
    os.darwin.systemManagerModules = [darwinManagedSettingsModule];
  };
}
