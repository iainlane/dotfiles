{config, ...}: let
  inherit (config.flake.modules) gnome;
  vmHost = config.flake.modules."vm-host";
  secureBoot = config.flake.modules."secure-boot";
in {
  flake.profiles.desktop.os.nixos = {
    modules = [gnome vmHost secureBoot];

    homeManagerModule = {pkgs, ...}: {
      home.packages = with pkgs; [
        code-cursor-fhs
        google-chrome
      ];

      services.gpg-agent.pinentry = {
        package = pkgs.pinentry-gnome3;
        program = "pinentry-gnome3";
      };

      xdg.mimeApps = {
        enable = true;
        defaultApplications = {
          "text/html" = "google-chrome.desktop";
          "x-scheme-handler/http" = "google-chrome.desktop";
          "x-scheme-handler/https" = "google-chrome.desktop";
          "x-scheme-handler/about" = "google-chrome.desktop";
          "x-scheme-handler/unknown" = "google-chrome.desktop";
        };
      };
    };

    nixosModule = {pkgs, ...}: {
      fonts.packages = with pkgs; [
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
    };
  };
}
