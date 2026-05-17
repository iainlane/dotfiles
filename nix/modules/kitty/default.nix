_: let
  homeManagerModule = {pkgs, ...}: {
    programs.kitty = {
      enable = true;

      shellIntegration.enableZshIntegration = true;

      settings = {
        font_family = "MonaspiceNe NFM";
        font_features = "MonaspiceNeNFM-Regular +ss01 +ss02 +ss03 +ss04 +liga";

        cursor_shape = "block";
        shell_integration = "enabled no-cursor";
        copy_on_select = "no";
        clipboard_control = "write-clipboard read-clipboard";

        enabled_layouts = "splits,stack";
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
        "super+n" = "new_os_window";
        "super+t" = "new_tab";
        "super+w" = "close_tab";
        "super+shift+w" = "close_os_window";
        "super+enter" = "toggle_layout stack";
        "super+shift+enter" = "toggle_layout stack";

        "super+1" = "goto_tab 1";
        "super+2" = "goto_tab 2";
        "super+3" = "goto_tab 3";
        "super+4" = "goto_tab 4";
        "super+5" = "goto_tab 5";
        "super+6" = "goto_tab 6";
        "super+7" = "goto_tab 7";
        "super+8" = "goto_tab 8";
        "super+9" = "goto_tab -1";
        "super+shift+]" = "next_tab";
        "super+shift+[" = "previous_tab";
        "ctrl+tab" = "next_tab";
        "ctrl+shift+tab" = "previous_tab";

        "super+[" = "previous_window";
        "super+]" = "next_window";
        "super+ctrl+left" = "resize_window narrower";
        "super+ctrl+right" = "resize_window wider";
        "super+ctrl+up" = "resize_window taller";
        "super+ctrl+down" = "resize_window shorter";
        "super+ctrl+equal" = "resize_window reset";

        "super+k" = "clear_terminal to_cursor active";
        "super+f" = "show_scrollback";
        "super+home" = "scroll_home";
        "super+end" = "scroll_end";
        "super+comma" = "edit_config_file";
        "super+shift+comma" = "load_config_file";
        "super+ctrl+f" = "toggle_fullscreen";

        "super+up" = "scroll_to_prompt -1";
        "super+down" = "scroll_to_prompt 1";
        "super+shift+up" = "scroll_to_prompt -1";
        "super+shift+down" = "scroll_to_prompt 1";
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
    programs.kitty.settings.font_size = 10;
  };
in {
  flake.modules.kitty = {
    homeManagerModules = [homeManagerModule];
    os = {
      darwin.homeManagerModules = [darwinHomeManagerModule];
      linux.homeManagerModules = [linuxHomeManagerModule];
      nixos.homeManagerModules = [linuxHomeManagerModule];
    };
  };
}
