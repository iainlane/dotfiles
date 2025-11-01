# Desktop profile - for machines with a graphical environment.
#
# Adds GUI applications (browser, messaging, VS Code), fonts, AI coding tools,
# and the Ghostty terminal. Also configures gpg-agent for SSH key management.
#
# Include this on workstations but not on headless servers.
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
