_: let
  nixosModule = {pkgs, ...}: {
    services = {
      desktopManager.gnome.enable = true;
      displayManager.gdm = {
        enable = true;
        wayland = true;
      };
      gnome = {
        core-developer-tools.enable = true;
        games.enable = true;
      };
      usbguard = {
        enable = true;
        dbus.enable = true;
        IPCAllowedGroups = ["wheel"];
        presentDevicePolicy = "allow";
      };
    };

    programs.dconf.enable = true;

    environment.gnome.excludePackages = with pkgs; [
      gnome-tour
    ];
  };

  extensions = pkgs:
    with pkgs.gnomeExtensions; [
      bing-wallpaper-changer
      night-theme-switcher
    ];

  homeManagerModule = {pkgs, ...}: let
    exts = extensions pkgs;
  in {
    home.packages = exts;

    dconf.settings = {
      "org/gnome/desktop/background" = {
        picture-options = "zoom";
      };
      "org/gnome/desktop/interface" = {
        clock-format = "24h";
        color-scheme = "prefer-dark";
        font-antialiasing = "rgba";
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
      "org/gnome/settings-daemon/plugins/color" = {
        night-light-enabled = true;
        night-light-schedule-automatic = true;
      };
      "org/gnome/shell" = {
        enabled-extensions = map (e: e.extensionUuid) exts;
      };
      "org/gnome/shell/extensions/bingwallpaper" = {
        hide = true;
      };
      "org/gnome/shell/keybindings" = {
        shift-overview-up = [""];
        shift-overview-down = [""];
      };
    };
  };
in {
  flake.modules.gnome = {
    nixosModules = [nixosModule];
    os.nixos.homeManagerModules = [homeManagerModule];
  };
}
