# Configure Claude Code: home-manager module for the package and shared MCP
# integration, plus system-level managed settings so that
# ~/.claude/settings.json can be written using `/config` etc.
_: let
  # Claude Code looks for managed settings at OS-specific paths:
  #   Linux: /etc/claude-code/managed-settings.json
  #   macOS: /Library/Application Support/ClaudeCode/managed-settings.json
  #
  # On Linux, `environment.etc` maps directly to /etc which is the right
  # location. On macOS the target is /Library (not /etc), so we symlink the
  # store path into place via an activation script — the same mechanism that
  # `environment.etc` itself uses under the hood.
  #
  # The policy itself is exposed as the option
  # `dotfiles.claudeCode.managedSettings`. Other modules may contribute
  # additional keys (e.g. `permissions.deny` lists) and definitions are
  # merged using the claude-managed-settings flake's `mergeSettingsList`,
  # which concatenates and dedupes the `permissions.{deny,ask,allow}` lists
  # and recursively updates everything else.
  # Shared option declaration and base value. Keeps the policy data in one
  # place; OS-specific modules below import this and add the file-placement
  # step appropriate to the target (environment.etc vs. /Library symlink).
  commonModule = {
    lib,
    pkgs,
    inputs,
    ...
  }: let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (inputs.llm-agents.packages.${system}) ccstatusline;
  in {
    options.dotfiles.claudeCode.managedSettings = lib.mkOption {
      type = lib.mkOptionType {
        name = "claude-code-managed-settings";
        description = "Claude Code managed-settings.json policy";
        check = builtins.isAttrs;
        merge = _loc: defs:
          inputs.claude-managed-settings.lib.mergeSettingsList
          (map (d: d.value) defs);
      };
      default = {};
      description = ''
        Contents of Claude Code's system-wide managed-settings.json policy.
        Other modules may contribute to this attrset; definitions are merged
        with the claude-managed-settings flake's algorithm, which concats
        and dedupes the `permissions.{deny,ask,allow}` lists and recursively
        updates everything else.
      '';
    };

    # Sort this last so that the config here _overrides_ any incoming systemwide
    # config.
    config.dotfiles.claudeCode.managedSettings = lib.mkAfter {
      allowManagedPermissionRulesOnly = false;
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
        command = "${ccstatusline}/bin/ccstatusline";
        padding = 0;
      };
      tui = "fullscreen";
      voiceEnabled = true;
    };
  };

  # Linux/NixOS: write via environment.etc. Used for both NixOS and
  # system-manager-linux — both surfaces expose environment.etc.
  linuxManagedSettingsModule = {
    config,
    pkgs,
    ...
  }: {
    imports = [commonModule];

    environment.etc."claude-code/managed-settings.json".source =
      (pkgs.formats.json {}).generate "managed-settings.json"
      config.dotfiles.claudeCode.managedSettings;
  };

  # Darwin: symlink the generated file from /Library. nix-darwin exposes
  # `system.activationScripts.postActivation` for this; system-manager
  # (linux) does not, which is why this module is gated to darwin only.
  darwinManagedSettingsModule = {
    config,
    pkgs,
    ...
  }: let
    settingsFile =
      (pkgs.formats.json {}).generate "managed-settings.json"
      config.dotfiles.claudeCode.managedSettings;
    darwinPath = "/Library/Application Support/ClaudeCode";
  in {
    imports = [commonModule];

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
