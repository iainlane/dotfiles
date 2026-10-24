{pkgs-unstable, ...}: let
  rea = import ./runtime.nix {pkgs = pkgs-unstable;};
in {
  imports = [./shared.nix];

  home.packages = [rea];
  dotfiles.ai.skills.reverse-engineer-anything = "${rea}/share/skills/rea/reverse-engineer-anything";
}
