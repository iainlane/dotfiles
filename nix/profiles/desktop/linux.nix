{
  flake.profiles.desktop.os.linux.homeManagerModule = {pkgs, ...}: {
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
}
