_: {
  flake.homeManagerModules.desktop = {
    pkgs,
    modulesPath,
    ...
  }: {
    imports = [
      (modulesPath + /ai)
      (modulesPath + /ghostty)
      (modulesPath + /kitty)
      (modulesPath + /zed-editor)
    ];

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

      # uvx is used by Claude Code etc for MCPs
      uv
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
