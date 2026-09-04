{pkgs, ...}: {
  programs.ghostty = {
    package = pkgs.ghostty;
    settings.font-size = 10;
  };
}
