{pkgs-unstable, ...}: let
  rea = import ./runtime.nix {pkgs = pkgs-unstable;};
in {
  imports = [./shared.nix];

  home.packages = [rea pkgs-unstable.ghidra pkgs-unstable.kuna];
  dotfiles.ai.bundles.rea.skills.reverse-engineer-anything.directory = "${rea}/share/skills/rea/reverse-engineer-anything";
}
