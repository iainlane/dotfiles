{
  lib,
  callPackage,
}:
callPackage ../build-support/larapaper-web-library {
  library = "chartkick";
  source = lib.importJSON ./source.json;
  files = {
    "chartkick.min.js" = "dist/chartkick.js";
    "LICENSE.txt" = "LICENSE.txt";
  };
}
