let
  common = import ./common.nix;

  # `catppuccin.sources.<port>` is the built port package; the per-app modules
  # read their themes from it, which is IFD. Point the ports we theme at
  # native-fetched inputs that mirror the installed layout (themes flattened to
  # the package root), so those reads happen against an evaluation-time path.
  # The `sources` option applies `recursiveUpdate` over the defaults, so a
  # string value replaces just that port and leaves the rest untouched.
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
        (sourceOverrides args)
        (common.selectedCatppuccin args).homeModules.catppuccin
      ]
      ++ common.channelDefaults args;
  }
