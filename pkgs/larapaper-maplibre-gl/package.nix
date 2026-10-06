{
  lib,
  callPackage,
}:
callPackage ../build-support/larapaper-web-library {
  library = "maplibre-gl";
  source = lib.importJSON ./source.json;
  files = {
    "maplibre-gl.js" = "dist/maplibre-gl.js";
    "maplibre-gl.css" = "dist/maplibre-gl.css";
    "LICENSE.txt" = "dist/LICENSE.txt";
  };
}
