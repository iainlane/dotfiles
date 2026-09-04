{pkgs, ...}: {
  services = {
    desktopManager.gnome.enable = true;
    displayManager.gdm.enable = true;
    gnome = {
      core-developer-tools.enable = true;
      games.enable = true;
    };
  };

  programs.dconf.enable = true;

  environment.gnome.excludePackages = with pkgs; [
    gnome-tour
  ];
}
