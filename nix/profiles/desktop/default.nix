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
  ];

  flake.profiles.desktop.modules = commonModules;

  flake.profiles.desktop.homeManagerModule = {pkgs, ...}: {
    fonts.fontconfig.enable = true;

    home.packages = with pkgs; [
      spotify
      telegram-desktop

      cascadia-code
      monaspace
      nerd-fonts.caskaydia-cove
      nerd-fonts.caskaydia-mono
      nerd-fonts.fira-code
      nerd-fonts.hack
      nerd-fonts.monaspace
      powerline-fonts
      roboto

      # Keep uv handy for ad-hoc Python tooling.
      uv
    ];

    programs.vscode = {
      enable = true;

      profiles.default.enableMcpIntegration = true;
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
