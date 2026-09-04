{pkgs, ...}: {
  home.packages = with pkgs; [
    aichat
    mods
    oterm
  ];
}
