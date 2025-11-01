{pkgs, ...}: {
  programs.kitty = {
    enable = true;

    shellIntegration.enableZshIntegration = true;

    settings = {
      font_family = "MonaspiceNe NFM";
      font_size =
        if pkgs.stdenv.isLinux
        then 11
        else 12;

      # Font features (ligatures)
      font_features = "MonaspiceNeNFM-Regular +ss01 +ss02 +ss03 +ss04 +liga";

      cursor_shape = "block";
      copy_on_select = "no";
      clipboard_control = "write-clipboard read-clipboard";

      # macOS-specific settings
      macos_titlebar_color = "background";
      macos_option_as_alt = "left";
    };

    keybindings = {
      # Move cursor one word left
      "alt+left" = "send_text all \\x1b[1;3D";
      # Move cursor one word right
      "alt+right" = "send_text all \\x1b[1;3C";
      # Move cursor to beginning of line (Ctrl-A)
      "cmd+left" = "send_text all \\x01";
      # Move cursor to end of line (Ctrl-E)
      "cmd+right" = "send_text all \\x05";
      # Delete word backwards (Ctrl-W)
      "alt+backspace" = "send_text all \\x17";
      # Delete to beginning of line (Ctrl-U)
      "cmd+backspace" = "send_text all \\x15";
      # Delete word forward
      "alt+delete" = "send_text all \\x1bd";
      # Delete to end of line (Ctrl-K)
      "cmd+delete" = "send_text all \\x0b";
      # Move cursor to beginning of line
      "home" = "send_text all \\x01";
      # Move cursor to end of line
      "end" = "send_text all \\x05";
      # Page up
      "page_up" = "send_text all \\x1b[5~";
      # Page down
      "page_down" = "send_text all \\x1b[6~";
      # Shift+Enter for newline
      "shift+enter" = "send_text all \\n";
      # New split right
      "super+d" = "launch --location=vsplit --cwd=current";
      # New split down
      "super+shift+d" = "launch --location=hsplit --cwd=current";
      # Goto split left
      "super+alt+left" = "neighboring_window left";
      # Goto split right
      "super+alt+right" = "neighboring_window right";
      # Goto split up
      "super+alt+up" = "neighboring_window up";
      # Goto split down
      "super+alt+down" = "neighboring_window down";
    };
  };

  # Automatic dark/light theme switching based on OS preference
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
}
