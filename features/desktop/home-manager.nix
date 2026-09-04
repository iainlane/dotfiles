{pkgs, ...}: {
  home.packages = with pkgs; [
    spotify
    telegram-desktop
  ];
}
