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

    home.packages = with pkgs; [
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

    fonts.fontconfig.enable = true;
  };
}
