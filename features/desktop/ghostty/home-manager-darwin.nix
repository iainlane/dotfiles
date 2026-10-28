{pkgs, ...}: {
  programs.ghostty = {
    package = pkgs.ghostty-bin;
    settings = {
      auto-update = "off";
      font-size = 12;
      macos-titlebar-style = "tabs";
      macos-option-as-alt = "left";
    };
  };
}
