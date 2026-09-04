{pkgs, ...}: {
  package = pkgs.gnomeExtensions.bing-wallpaper-changer;

  dconfSettings = {
    "org/gnome/shell/extensions/bingwallpaper" = {
      hide = true;
    };
  };
}
