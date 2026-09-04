{config, ...}: let
  inherit (config.flake) features;
in {
  imports = [
    ./linux.nix
    ./darwin.nix
    ./nixos
  ];

  flake.features.desktop.includes = [
    features.ai
    features.ghostty
    features.kitty
    features.voxtype
    features.zed-editor
  ];

  flake.features.desktop.homeManager = {pkgs, ...}: {
    fonts.fontconfig.enable = true;

    home.packages = with pkgs; [
      spotify
      telegram-desktop
    ];

    programs.vscode = {
      enable = true;

      profiles.default = {
        enableMcpIntegration = true;
        extensions = with pkgs.vscode-extensions; [
          catppuccin.catppuccin-vsc
        ];
      };
    };

    services.gpg-agent = {
      enable = true;

      enableSshSupport = false;
    };

    services.ssh-agent = {
      enable = true;
    };
  };
}
