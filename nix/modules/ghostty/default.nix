_: let
  homeManagerModule = {
    programs.ghostty = {
      enable = true;

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

        keybind = [
          "alt+left=csi:1;3D"
          "alt+right=csi:1;3C"
          "cmd+left=text:\\x01"
          "cmd+right=text:\\x05"
          "alt+backspace=text:\\x17"
          "cmd+backspace=text:\\x15"
          "alt+delete=esc:d"
          "cmd+delete=text:\\x0B"
          "home=text:\\x01"
          "end=text:\\x05"
          "page_up=csi:5~"
          "page_down=csi:6~"
          "shift+enter=text:\\n"
          "super+shift+d=new_split:down"
          "super+d=new_split:right"
          "super+alt+left=goto_split:left"
          "super+alt+right=goto_split:right"
          "super+alt+up=goto_split:up"
          "super+alt+down=goto_split:down"
        ];

        clipboard-read = "allow";
      };
    };
  };

  darwinHomeManagerModule = {pkgs, ...}: {
    programs.ghostty = {
      package = pkgs.ghostty-bin;
      settings = {
        font-size = 12;
        macos-titlebar-style = "tabs";
        macos-option-as-alt = "left";
      };
    };
  };

  linuxHomeManagerModule = {pkgs, ...}: {
    programs.ghostty = {
      package = pkgs.ghostty;
      settings.font-size = 11;
    };
  };
in {
  flake.modules.ghostty = {
    homeManagerModules = [homeManagerModule];
    os.darwin.homeManagerModules = [darwinHomeManagerModule];
    os.linux.homeManagerModules = [linuxHomeManagerModule];
  };
}
