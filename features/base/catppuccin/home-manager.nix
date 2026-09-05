let
  common = import ./common.nix;

  # `catppuccin.sources.<port>` is the built port package, and the bottom
  # module reads its theme from that path during evaluation, which is IFD.
  # Point `catppuccin.sources.bottom` at the flake input's `themes`
  # directory, which mirrors the installed layout, so that read happens
  # against an evaluation-time path. The `sources` option applies
  # `recursiveUpdate` over the defaults, so a string value replaces just that
  # port and leaves the rest untouched.
  sourceOverrides = {inputs, ...}: {
    catppuccin.sources.bottom = "${inputs.catppuccin-bottom}/themes";
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
