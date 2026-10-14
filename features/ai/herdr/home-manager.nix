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

  inherit (inputs.llm-agents.packages.${system}) herdr;

  packages = pkgs.callPackage ./packages.nix {};

  integrations = "${herdr}/share/herdr/integrations";

  codexHome =
    config.home.sessionVariables.CODEX_HOME
      or "${config.home.homeDirectory}/.codex";

  # Catppuccin's colours as hex values, by flavour and then by name.
  catppuccin =
    lib.mapAttrs (_: flavour: lib.mapAttrs (_: colour: colour.hex) flavour.colors)
    (removeAttrs (lib.importJSON (inputs.catppuccin-palette + "/palette.json")) ["version"]);

  # The colours for the sidebar rows below. Herdr's inline token styles accept
  # only hex colours, and those colours stay the same when Herdr switches
  # between its light and dark themes. The rows therefore use the configured
  # Catppuccin flavour in both themes.
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
    default = [pkgs.herdr-ctx-bar pkgs.herdr-disp-model];
    defaultText = lib.literalExpression "[pkgs.herdr-ctx-bar pkgs.herdr-disp-model]";
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
          # Herdr records that onboarding is finished by writing this setting
          # to `config.toml`, which Home Manager makes read-only.
          onboarding = false;

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
            # The default width of 26 columns cuts off the model and effort
            # after the agent's name.
            sidebar_width = 36;

            # Herdr's default rows, with Model Display's `$model` and
            # `$effort` after the agent's name and Context Bar's bar below.
            # Context Bar sets one of its three tokens for each agent, so the
            # bar takes the colour of the band that the context usage is in:
            # below 50%, from 50% to 79%, or 80% and above.
            sidebar.agents.rows = [
              ["state_icon" "machine" "workspace" "tab"]
              [
                # Each harness's name is close to its brand's colour. Green,
                # yellow and red are left for the Context Bar.
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

      home.activation.herdrPlugins = lib.hm.dag.entryAfter ["writeBoundary"] ''
        run ${lib.getExe (packages.pluginSync {inherit herdr;})} \
          ${builtins.storeDir} \
          ${lib.escapeShellArgs (map (plugin: plugin.pluginRoot) cfg.plugins)}
      '';

      # Herdr ignores the whole of `config.toml` and uses its defaults when one
      # setting does not parse. Checking the file here makes such a setting
      # fail the build.
      home.extraBuilderCommands = ''
        HOME=$(mktemp -d) HERDR_CONFIG_PATH=${config.xdg.configFile."herdr/config.toml".source} \
          ${lib.getExe herdr} config check
      '';
    }

    # Herdr's settings show the Claude Code or Codex integration as installed
    # when Herdr's hook script is in the agent's configuration directory, and
    # offer to install the integration otherwise. Installing it would also add
    # Herdr's hook to the agent's own settings, and the hook would then run
    # twice. The hooks in `./system.nix` run the copies in the Nix store.
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

    # OpenCode loads every plugin in `plugins/`, and its TUI loads the plugins
    # that `tui.json` lists.
    (lib.mkIf (hasHarness hostConfig "opencode") {
      xdg.configFile = {
        "opencode/plugins/herdr-agent-state.js".source = "${integrations}/opencode/herdr-agent-state.js";
        "opencode/herdr-tui-session.js".source = "${integrations}/opencode/herdr-tui-session.js";
      };

      programs.opencode.tui.plugin = ["./herdr-tui-session.js"];
    })

    # OpenCode 2's background server runs outside the pane, so Herdr's plugin
    # for OpenCode 2 runs in the TUI. `dotfiles.opencode2` exists only on a
    # host with `ai.opencode2`.
    (lib.optionalAttrs (hasHarness hostConfig "opencode2") {
      dotfiles.opencode2.cliConfig.plugins = [
        "${packages.opencode2TuiPlugin {inherit herdr;}}/herdr-opencode"
      ];
    })
  ];
}
