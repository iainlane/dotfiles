{pkgs, ...}: {
  home.packages = import ./packages.nix pkgs;
}
