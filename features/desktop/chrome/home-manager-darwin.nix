{
  pkgs,
  lib,
  ...
}: {
  # macOS has no declarative API for default browser, so we use an activation script.
  home.activation.setDefaultBrowser = lib.hm.dag.entryAfter ["writeBoundary"] ''
    ${pkgs.defaultbrowser}/bin/defaultbrowser chrome
  '';
}
