_: {
  flake.profiles.desktop.os.darwin.homeManagerModule = {
    pkgs,
    lib,
    ...
  }: {
    home.packages = with pkgs; [
      code-cursor
    ];

    # macOS has no declarative API for default browser, so we use an activation script.
    home.activation.setDefaultBrowser = lib.hm.dag.entryAfter ["writeBoundary"] ''
      ${pkgs.defaultbrowser}/bin/defaultbrowser chrome
    '';
  };

  flake.profiles.desktop.os.darwin.systemManagerModule = {
    lib,
    ...
  }: {
    homebrew.casks = [
      "claude"
      "google-chrome"
      "warp"
      "wine-stable"
    ];
  };
}
