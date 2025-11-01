_: {
  flake.homeManagerModules.desktop-linux = {pkgs, ...}: {
    home.packages = with pkgs; [
      code-cursor-fhs
      google-chrome
    ];

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
