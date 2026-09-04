let
  common = import ./common.nix;
in
  args: {
    imports =
      [
        common.defaults
        (common.selectedCatppuccin args).nixosModules.catppuccin
      ]
      ++ common.channelDefaults args;
  }
