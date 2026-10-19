let
  common = import ./common.nix;

  # Theme modules read these sources during evaluation. Use flake sources so
  # evaluation does not require a builder for the host's platform. Keep them as
  # strings: `sources` applies `recursiveUpdate` over the default packages,
  # which would merge an attribute set into the package derivation.
  sourceOverrides = {inputs, ...}: {
    catppuccin.sources = {
      bottom = "${inputs.catppuccin-bottom}/themes";
      palette = "${inputs.catppuccin-palette}";
    };
  };
in
  args: {
    imports =
      [
        common.defaults
        sourceOverrides
        (common.selectedCatppuccin args).homeModules.catppuccin
      ]
      ++ common.channelDefaults args;
  }
