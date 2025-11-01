# Set Chrome as default browser via activation script. macOS has no declarative
# API for this, so we invoke `defaultbrowser` after Chrome is installed.
{
  pkgs,
  lib,
  ...
}: {
  home.packages = with pkgs; [
    code-cursor
  ];

  home.activation.setDefaultBrowser = lib.hm.dag.entryAfter ["writeBoundary"] ''
    ${pkgs.defaultbrowser}/bin/defaultbrowser chrome
  '';
}
