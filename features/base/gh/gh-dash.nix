# gh-dash renders a dashboard of pull requests and issues; run it as
# `gh dash`. Sections are left at the built-in defaults, which the generated
# configuration file extends with theming and keybindings.
#
# The theme reproduces the colour roles of the `catppuccin/gh-dash` port,
# with values taken from the upstream `catppuccin/palette` repo via the
# `catppuccin-palette` flake input, so the colours stay in sync with the
# rest of the ecosystem without IFD or vendored YAML.
{
  config,
  inputs,
  lib,
  ...
}: let
  palette = lib.importJSON (inputs.catppuccin-palette + "/palette.json");

  colours = lib.mapAttrs (_: colour: colour.hex) palette.${config.catppuccin.flavor}.colors;
  accent = colours.${config.catppuccin.accent};
in {
  programs.gh-dash = {
    enable = true;

    settings = {
      theme.colors = {
        text = {
          primary = colours.text;
          secondary = accent;
          inverted = colours.crust;
          faint = colours.subtext1;
          warning = colours.yellow;
          success = colours.green;
          error = colours.red;
        };

        background.selected = colours.surface0;

        border = {
          primary = accent;
          secondary = colours.surface1;
          faint = colours.surface0;
        };
      };

      # Open the selected pull request's checks in gh-enhance, as suggested
      # by https://www.gh-dash.dev/companions/enhance/dash-integration/.
      keybindings.prs = [
        {
          key = "T";
          command = "gh enhance -R {{.RepoName}} {{.PrNumber}}";
        }
      ];
    };
  };
}
