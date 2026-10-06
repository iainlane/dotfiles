{
  lib,
  callPackage,
}:
callPackage ../build-support/larapaper-web-library {
  library = "highcharts";
  source = lib.importJSON ./source.json;
  files = {
    "highcharts.js" = "highcharts.js";
    "pattern-fill.js" = "modules/pattern-fill.js";
    "package.json" = "package.json";
    "README.md" = "README.md";
  };
}
