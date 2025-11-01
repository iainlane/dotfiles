_: {
  flake.homeManagerModules.desktop-darwin = {
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
}
