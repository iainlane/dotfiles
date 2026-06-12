{pkgs, ...}: {
  programs.ghostty = {
    package = pkgs.ghostty-bin;
    settings = {
      font-size = 12;
      macos-titlebar-style = "tabs";
      macos-option-as-alt = "left";
    };
  };
}
