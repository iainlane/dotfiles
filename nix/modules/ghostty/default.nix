{pkgs, ...}: {
  programs.ghostty = {
    enable = true;
    package =
      if pkgs.stdenv.isLinux
      then pkgs.ghostty
      else pkgs.ghostty-bin;

    enableZshIntegration = true;

    settings = {
      font-family = "MonaspiceNe NFM";
      font-feature = [
        "ss01" # != and ===
        "ss02" # <= and >=
        "ss03" # -> and ~>
        "ss04" # <> and </>
        "liga" # //, ..., ||
      ];

      theme = "dark:Catppuccin Mocha,light:Catppuccin Latte";
      cursor-style = "block";
      shell-integration-features = "no-cursor";
      copy-on-select = false;
      font-size =
        if pkgs.stdenv.isLinux
        then 11
        else 12;
      macos-titlebar-style = "tabs";
      macos-option-as-alt = "left";

      keybind = [
        # Move cursor one word left
        "alt+left=csi:1;3D"
        # Move cursor one word right
        "alt+right=csi:1;3C"
        # Move cursor to beginning of line (Ctrl-A)
        "cmd+left=text:\\x01"
        # Move cursor to end of line (Ctrl-E)
        "cmd+right=text:\\x05"
        # Delete word backwards (Ctrl-W)
        "alt+backspace=text:\\x17"
        # Delete to beginning of line (Ctrl-U)
        "cmd+backspace=text:\\x15"
        # Delete word forward
        "alt+delete=esc:d"
        # Delete to end of line (Ctrl-K)
        "cmd+delete=text:\\x0B"
        # Move cursor to beginning of line
        "home=text:\\x01"
        # Move cursor to end of line
        "end=text:\\x05"
        # Page up
        "page_up=csi:5~"
        # Page down
        "page_down=csi:6~"
        # Shift+Enter for newline
        "shift+enter=text:\\n"
        # New split right
        "super+shift+d=new_split:down"
        # New split down
        "super+d=new_split:right"
        # Goto split left
        "super+alt+left=goto_split:left"
        # Goto split right
        "super+alt+right=goto_split:right"
        # Goto split up
        "super+alt+up=goto_split:up"
        # Goto split down
        "super+alt+down=goto_split:down"
      ];

      clipboard-read = "allow";
    };
  };
}
