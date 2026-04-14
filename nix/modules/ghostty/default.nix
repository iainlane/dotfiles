{inputs, ...}: let
  # Use the unstable home-manager ghostty module even on the stable channel.
  # The stable branch has the systemd service integration (PR #8130) but is
  # missing the X-SwitchMethod=keep-old drop-in (PR #8490) that prevents
  # home-manager activation from restarting the service and killing all open
  # terminal sessions.
  unstableGhosttyModule = {
    disabledModules = ["programs/ghostty.nix"];
    imports = [
      (import "${inputs.home-manager}/modules/programs/ghostty.nix")
    ];
  };

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
          "super+n=new_window"
          "super+t=new_tab"
          "super+w=close_tab:this"
          "super+enter=toggle_split_zoom"
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
      settings.font-size = 10;
    };
  };
in {
  flake.modules.ghostty = {
    homeManagerModules = [unstableGhosttyModule homeManagerModule];
    os = {
      darwin.homeManagerModules = [darwinHomeManagerModule];
      linux.homeManagerModules = [linuxHomeManagerModule];
      nixos.homeManagerModules = [linuxHomeManagerModule];
    };
  };
}
