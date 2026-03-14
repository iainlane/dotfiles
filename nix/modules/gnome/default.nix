_: let
  nixosModule = {pkgs, ...}: {
    services.desktopManager.gnome.enable = true;
    services.displayManager.gdm = {
      enable = true;
      wayland = true;
    };

    programs.dconf.enable = true;

    environment.gnome.excludePackages = with pkgs; [
      gnome-tour
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
        natural-scroll = false;
      };
      "org/gnome/mutter" = {
        edge-tiling = true;
        dynamic-workspaces = true;
        workspaces-only-on-primary = true;
      };
      "org/gnome/desktop/input-sources" = {
        xkb-options = ["compose:caps"];
      };
      "org/gnome/desktop/wm/preferences" = {
        button-layout = "appmenu:minimize,maximize,close";
      };
      "org/gnome/desktop/wm/keybindings" = {
        switch-to-workspace-left = ["<Control>Left"];
        switch-to-workspace-right = ["<Control>Right"];
      };
    };
  };
in {
  flake.modules.gnome = {
    nixosModules = [nixosModule];
    os.nixos.homeManagerModules = [homeManagerModule];
  };
}
