{hasHarness}: {
  config,
  hostConfig,
  inputs,
  lib,
  pkgs,
  system,
  ...
}: let
  cfg = config.dotfiles.herdr;

  inherit (inputs.llm-agents.packages.${system}) herdr plannotator-tui;

  packages = pkgs.callPackage ./packages.nix {};

  integrations = "${herdr}/share/herdr/integrations";

  codexHome =
    config.home.sessionVariables.CODEX_HOME
      or "${config.home.homeDirectory}/.codex";

  catppuccin =
    lib.mapAttrs (_: flavour: lib.mapAttrs (_: colour: colour.hex) flavour.colors)
    (removeAttrs (lib.importJSON (inputs.catppuccin-palette + "/palette.json")) ["version"]);

  # Inline token styles require hex colours and do not switch with the theme.
  tokenColours = catppuccin.${config.catppuccin.flavor};

  themeColours = flavour: let
    colours = catppuccin.${flavour};
  in {
    accent = colours.blue;
    sidebar_bg = colours.crust;
    active_row_bg = colours.surface0;
    selection_bg = colours.surface1;
    surface_dim = colours.surface2;
  };
in {
  options.dotfiles.herdr.plugins = lib.mkOption {
    type = with lib.types; listOf package;
    default = [pkgs.herdr-ctx-bar pkgs.herdr-disp-model pkgs.herdr-annotate pkgs.herdr-annotate-links];
    defaultText = lib.literalExpression "[pkgs.herdr-ctx-bar pkgs.herdr-disp-model pkgs.herdr-annotate pkgs.herdr-annotate-links]";
    description = ''
      Herdr plugins to link and enable. Each package specifies the plugin's
      directory in `passthru.pluginRoot`. Activation also removes every
      plugin linked from the Nix store that the list does not contain.
    '';
  };

  config = lib.mkMerge [
    {
      programs.herdr = {
        enable = true;
        package = herdr;

        settings = {
          onboarding = false;

          update = {
            version_check = false;
            manifest_check = false;
          };

          keys = {
            new_worktree = "prefix+ctrl+c";
            open_worktree = "prefix+ctrl+o";
            remove_worktree = "prefix+ctrl+d";
            last_pane = "prefix+t";
            previous_agent = "prefix+shift+k";
            next_agent = "prefix+shift+j";
            switch_workspace = "prefix+shift+1..9";
            open_notification_target = "prefix+f";

            command = [
              {
                key = "prefix+a";
                type = "plugin_action";
                command = "annotate.capture";
                description = "Annotate selected text";
              }
              {
                key = "prefix+shift+a";
                type = "plugin_action";
                command = "annotate.copy-context";
                description = "Copy annotations as feedback";
              }
              {
                key = "prefix+ctrl+a";
                type = "plugin_action";
                command = "annotate.copy-archive";
                description = "Copy and archive annotations";
              }
              {
                key = "prefix+ctrl+v";
                type = "plugin_action";
                command = "annotate.paste-archive";
                description = "Paste annotations without submitting and archive them";
              }
              {
                key = "prefix+ctrl+s";
                type = "plugin_action";
                command = "annotate.send-archive";
                description = "Send annotations to the agent and archive them";
              }
              {
                key = "prefix+m";
                type = "plugin_action";
                command = "annotate.manage";
                description = "Manage annotations";
              }
              {
                key = "prefix+o";
                type = "plugin_action";
                command = "annotate.open";
                description = "Review documents in this folder";
              }
              {
                key = "prefix+shift+l";
                type = "plugin_action";
                command = "annotate.last";
                description = "Review the agent's recent replies";
              }
              {
                key = "prefix+ctrl+l";
                type = "plugin_action";
                command = "annotate.last-newest";
                description = "Review the agent's newest reply";
              }
            ];
          };

          theme = {
            name = "catppuccin";
            auto_switch = true;
            light_name = "catppuccin-latte";
            dark_name = "catppuccin";

            # `catppuccin` is Herdr's Mocha theme.
            custom = {
              light = themeColours "latte";
              dark = themeColours "mocha";
            };
          };

          ui = {
            sidebar_width = 36;

            sidebar.agents.rows = [
              ["state_icon" "machine" "workspace" "tab"]
              [
                {
                  token = "agent";
                  rules = map (rule: rule // {ignore_case = true;}) [
                    {
                      equals = "claude";
                      fg = tokenColours.peach;
                    }
                    {
                      equals = "codex";
                      fg = tokenColours.teal;
                    }
                    {
                      equals = "opencode";
                      fg = tokenColours.sapphire;
                    }
                    {
                      equals = "pi";
                      fg = tokenColours.mauve;
                    }
                  ];
                }
                "$model"
                "$effort"
              ]
              # Context Bar populates only the token for the current usage band.
              [
                {
                  token = "$ctx_green";
                  fg = tokenColours.green;
                }
                {
                  token = "$ctx_yellow";
                  fg = tokenColours.yellow;
                }
                {
                  token = "$ctx_red";
                  fg = tokenColours.red;
                }
              ]
            ];
          };
        };
      };

      home = {
        packages = [plannotator-tui];

        activation.herdrPlugins = lib.hm.dag.entryAfter ["writeBoundary"] ''
          run ${lib.getExe (packages.pluginSync {inherit herdr;})} \
            ${builtins.storeDir} \
            ${lib.escapeShellArgs (map (plugin: plugin.pluginRoot) cfg.plugins)}
        '';

        # Herdr silently uses defaults if any config.toml setting is invalid.
        extraBuilderCommands = ''
          HOME=$(mktemp -d) HERDR_CONFIG_PATH=${config.xdg.configFile."herdr/config.toml".source} \
            ${lib.getExe herdr} config check
        '';
      };
    }

    # Herdr offers to install hooks unless these files exist. Installation
    # would duplicate the hooks already configured by ./system.nix.
    (lib.mkIf (hasHarness hostConfig "claude-code") {
      home.file."${config.programs.claude-code.configDir}/hooks/herdr-agent-state.sh".source = "${integrations}/claude/herdr-agent-state.sh";
    })

    (lib.mkIf (hasHarness hostConfig "codex") {
      home.file."${codexHome}/herdr-agent-state.sh".source = "${integrations}/codex/herdr-agent-state.sh";
    })

    (lib.mkIf (hasHarness hostConfig "pi") {
      home.file = {
        ".pi/agent/extensions/herdr-agent-state.ts".source = "${integrations}/pi/herdr-agent-state.ts";
        ".pi/agent/extensions/herdr-model-display.ts".source = pkgs.herdr-disp-model.piExtension;
      };
    })

    # OpenCode's server runs outside the pane, so Herdr needs a TUI plugin.
    # Use optionalAttrs: dotfiles.opencode is undeclared without ai.opencode.
    (lib.optionalAttrs (hasHarness hostConfig "opencode") {
      dotfiles.opencode.cliConfig.plugins = [
        "${packages.opencodeTuiPlugin {inherit herdr;}}/herdr-opencode"
      ];
    })
  ];
}
