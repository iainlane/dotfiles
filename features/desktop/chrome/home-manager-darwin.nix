{
  pkgs,
  lib,
  ...
}: {
  # macOS has no declarative setting for the default browser, so set it from
  # an activation script.
  home.activation.setDefaultBrowser = lib.hm.dag.entryAfter ["writeBoundary"] ''
    ${pkgs.defaultbrowser}/bin/defaultbrowser chrome
  '';
}
