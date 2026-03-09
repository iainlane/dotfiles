_: let
  nixosModule = {pkgs, ...}: {
    services.xserver = {
      desktopManager.gnome.enable = true;
      displayManager.gdm = {
        enable = true;
        wayland = true;
      };
    };

    programs.dconf.enable = true;

    environment.gnome.excludePackages = with pkgs; [
      epiphany
      geary
      gnome-maps
      gnome-music
      gnome-tour
      totem
    ];
  };

  homeManagerModule = {
    dconf.settings = {
      "org/gnome/desktop/interface" = {
        clock-format = "24h";
        color-scheme = "prefer-dark";
        gtk-theme = "adw-gtk3-dark";
      };
      "org/gnome/desktop/peripherals/touchpad" = {
        tap-to-click = true;
        natural-scroll = true;
      };
      "org/gnome/mutter" = {
        edge-tiling = true;
        dynamic-workspaces = true;
        workspaces-only-on-primary = true;
      };
      "org/gnome/desktop/wm/preferences" = {
        button-layout = "appmenu:minimize,maximize,close";
      };
    };
  };
in {
  flake.modules.gnome = {
    nixosModules = [nixosModule];
    os.nixos.homeManagerModules = [homeManagerModule];
  };
}
