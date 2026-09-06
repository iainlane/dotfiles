# There is no `catppuccin.sources` override here to match the one in
# `home-manager.nix`. The Home Manager ports whose themes are read with
# `importTOML` or `importJSON` need one, because those reads build the source
# package during evaluation. The only NixOS port enabled anywhere here is
# plymouth, which passes `catppuccin.sources.plymouth` to
# `boot.plymouth.themePackages` as a package. Upstream's `tty` port does read
# its palette during evaluation, so enabling it would need an override too.
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
