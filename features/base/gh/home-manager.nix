# The GitHub CLI and its extensions. gh-dash (configured in ./gh-dash.nix)
# adds a pull-request and issue dashboard, and gh-enhance a GitHub Actions
# TUI, invoked as `gh enhance [<pr-number> | <pr-url> | <run-url>]`.
{
  config,
  pkgs-unstable,
  ...
}: {
  programs.gh = {
    enable = true;

    # The extensions come from unstable on every channel: gh-stack stays in
    # step with the `gh-stack-skill` flake input, which tracks upstream
    # releases, and gh-enhance is only packaged in unstable.
    extensions = [
      pkgs-unstable.gh-enhance
      pkgs-unstable.gh-stack
    ];

    gitCredentialHelper.enable = true;
    settings.gitProtocol = "https";
  };

  # gh-enhance takes its theme from a bubbletint theme ID; the catppuccin
  # tints follow the flavour used by the rest of the configuration.
  home.sessionVariables.ENHANCE_THEME = "catppuccin_${config.catppuccin.flavor}";
}
