_: {
  imports = [
    ./linux.nix
    ./darwin.nix
    ./nixos
  ];

  flake.profiles.desktop.features = [
    "ai"
    "ghostty"
    "kitty"
    "zed-editor"
  ];

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
