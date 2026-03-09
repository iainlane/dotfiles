_: let
  homeManagerModule = {pkgs, ...}: {
    programs.kitty = {
      enable = true;

      shellIntegration.enableZshIntegration = true;

      settings = {
        font_family = "MonaspiceNe NFM";
        font_features = "MonaspiceNeNFM-Regular +ss01 +ss02 +ss03 +ss04 +liga";

        cursor_shape = "block";
        copy_on_select = "no";
        clipboard_control = "write-clipboard read-clipboard";
      };

      keybindings = {
        "alt+left" = "send_text all \\x1b[1;3D";
        "alt+right" = "send_text all \\x1b[1;3C";
        "cmd+left" = "send_text all \\x01";
        "cmd+right" = "send_text all \\x05";
        "alt+backspace" = "send_text all \\x17";
        "cmd+backspace" = "send_text all \\x15";
        "alt+delete" = "send_text all \\x1bd";
        "cmd+delete" = "send_text all \\x0b";
        "home" = "send_text all \\x01";
        "end" = "send_text all \\x05";
        "page_up" = "send_text all \\x1b[5~";
        "page_down" = "send_text all \\x1b[6~";
        "shift+enter" = "send_text all \\n";
        "super+d" = "launch --location=vsplit --cwd=current";
        "super+shift+d" = "launch --location=hsplit --cwd=current";
        "super+alt+left" = "neighboring_window left";
        "super+alt+right" = "neighboring_window right";
        "super+alt+up" = "neighboring_window up";
        "super+alt+down" = "neighboring_window down";
      };
    };

    xdg.configFile = {
      "kitty/dark-theme.auto.conf".text = ''
        include ${pkgs.kitty-themes}/share/kitty-themes/themes/Catppuccin-Mocha.conf
      '';
      "kitty/light-theme.auto.conf".text = ''
        include ${pkgs.kitty-themes}/share/kitty-themes/themes/Catppuccin-Latte.conf
      '';
      "kitty/no-preference-theme.auto.conf".text = ''
        include ${pkgs.kitty-themes}/share/kitty-themes/themes/Catppuccin-Mocha.conf
      '';
    };
  };

  darwinHomeManagerModule = {
    programs.kitty.settings = {
      font_size = 12;
      macos_titlebar_color = "background";
      macos_option_as_alt = "left";
    };
  };

  linuxHomeManagerModule = {
    programs.kitty.settings.font_size = 11;
  };
in {
  flake.modules.kitty = {
    homeManagerModules = [homeManagerModule];
    os.darwin.homeManagerModules = [darwinHomeManagerModule];
    os.linux.homeManagerModules = [linuxHomeManagerModule];
    os.nixos.homeManagerModules = [linuxHomeManagerModule];
  };
}
