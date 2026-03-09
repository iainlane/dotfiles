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
    homebrew.casks = [
      "google-chrome"
      "warp"
      "wine-stable"
    ];
  };
}
