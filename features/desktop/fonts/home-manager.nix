{pkgs, ...}: {
  fonts.fontconfig.enable = true;

  home.packages = import ./packages.nix pkgs;
}
