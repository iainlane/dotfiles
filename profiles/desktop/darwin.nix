{
  flake.profiles.desktop.os.darwin.homeManagerModule = {
    pkgs,
    lib,
    ...
  }: {
    home.packages =
      (with pkgs; [
        code-cursor
      ])
      ++ import ./fonts.nix pkgs;

    services.gpg-agent.pinentry = {
      package = pkgs.pinentry_mac;
      program = "pinentry-mac";
    };

    # macOS has no declarative API for default browser, so we use an activation script.
    home.activation.setDefaultBrowser = lib.hm.dag.entryAfter ["writeBoundary"] ''
      ${pkgs.defaultbrowser}/bin/defaultbrowser chrome
    '';
  };

  flake.profiles.desktop.os.darwin.systemManagerModule = {
    homebrew = {
      casks = [
        "google-chrome"
        "gstreamer-runtime"
        "warp"
        "wine-stable"
      ];

      # Keep Wine's cask dependency in the Brewfile so cleanup preserves it,
      # but leave its installation and upgrades to Wine.
      onActivation.extraEnv.HOMEBREW_BUNDLE_CASK_SKIP = "gstreamer-runtime";
    };
  };
}
