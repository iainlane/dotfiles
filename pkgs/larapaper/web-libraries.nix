{
  runCommand,
  fetchurl,
}: let
  highcharts = fetchurl {
    url = "https://registry.npmjs.org/highcharts/-/highcharts-12.3.0.tgz";
    hash = "sha256-Z94bQDYLolBYa9KcDW1HplvveJRKO0ZQQWqcsmPnugw=";
  };
  chartkick = fetchurl {
    url = "https://registry.npmjs.org/chartkick/-/chartkick-5.0.1.tgz";
    hash = "sha256-xsdpmwWoOdqxfAF/Pk2/BR+lhYOukHcdgOCT+kxV/fw=";
  };
  maplibre = fetchurl {
    url = "https://registry.npmjs.org/maplibre-gl/-/maplibre-gl-5.24.0.tgz";
    hash = "sha256-XL+DwyjJ05yyTj8s78m0B9ad0QS6C0HoTAv7sxxE4oM=";
  };
in
  runCommand "larapaper-web-libraries" {} ''
    mkdir -p "$out/js" highcharts chartkick maplibre
    tar -xf ${highcharts} -C highcharts --strip-components=1
    tar -xf ${chartkick} -C chartkick --strip-components=1
    tar -xf ${maplibre} -C maplibre --strip-components=1
    mkdir -p "$out/js/highcharts/12.3.0" "$out/js/chartkick/5.0.1" "$out/js/maplibre-gl/5.24.0"
    cp highcharts/highcharts.js "$out/js/highcharts/12.3.0/"
    cp highcharts/modules/pattern-fill.js "$out/js/highcharts/12.3.0/"
    cp chartkick/dist/chartkick.js "$out/js/chartkick/5.0.1/chartkick.min.js"
    cp maplibre/dist/maplibre-gl.{js,css} "$out/js/maplibre-gl/5.24.0/"
    cp highcharts/{package.json,README.md} "$out/js/highcharts/12.3.0/"
    cp chartkick/LICENSE.txt "$out/js/chartkick/5.0.1/"
    cp maplibre/dist/LICENSE.txt "$out/js/maplibre-gl/5.24.0/"
  ''
