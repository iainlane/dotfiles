_: {
  flake.homeManagerModules.desktop = {
    pkgs,
    mkProfileImports,
    modulesPath,
    ...
  }: {
    imports = mkProfileImports ./. [
      (modulesPath + /ai)
      (modulesPath + /ghostty)
    ];

    fonts.fontconfig.enable = true;

    home.packages = with pkgs; [
      code-cursor-fhs

      google-chrome

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
    ];

    programs.vscode = {
      enable = true;

      profiles.default.enableMcpIntegration = true;
    };

    services.gpg-agent = {
      enable = true;

      enableSshSupport = true;
      pinentry =
        if pkgs.stdenv.isDarwin
        then {
          package = pkgs.pinentry_mac;
          program = "pinentry-mac";
        }
        else {
          package = pkgs.pinentry-gnome3;
          program = "pinentry-gnome3";
        };
    };
  };
}
