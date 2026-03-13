{config, ...}: let
  inherit
    (config.flake.modules)
    ai
    ghostty
    kitty
    ;
  zedEditor = config.flake.modules."zed-editor";
  commonModules = [
    ai
    ghostty
    kitty
    zedEditor
  ];
in {
  imports = [
    ./linux.nix
    ./darwin.nix
    ./nixos.nix
  ];

  flake.profiles.desktop.modules = commonModules;

  flake.profiles.desktop.homeManagerModule = {pkgs, ...}: {
    fonts.fontconfig.enable = true;

    home.packages = with pkgs; [
      spotify
      telegram-desktop

      # Keep uv handy for ad-hoc Python tooling.
      uv
    ];

    programs.vscode = {
      enable = true;

      profiles.default = {
        enableMcpIntegration = true;
        extensions = with pkgs.vscode-extensions; [
          catppuccin.catppuccin-vsc
        ];
        userSettings = {
          "catppuccin.accentColor" = "mauve";
          "editor.semanticHighlighting.enabled" = true;
          "terminal.integrated.minimumContrastRatio" = 1;
          "window.autoDetectColorScheme" = true;
          "window.titleBarStyle" = "custom";
          "workbench.preferredDarkColorTheme" = "Catppuccin Mocha";
          "workbench.preferredLightColorTheme" = "Catppuccin Latte";
        };
      };
    };

    services.gpg-agent = {
      enable = true;

      enableSshSupport = false;
    };

    services.ssh-agent = {
      enable = true;
      enableZshIntegration = true;
    };
  };
}
