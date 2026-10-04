{
  lib,
  runCommand,
  fetchurl,
  updaters,
  python3,
}: let
  sources = lib.importJSON ./sources.json;
  archives = lib.mapAttrs (name: source:
    fetchurl {
      url = "https://registry.npmjs.org/${name}/-/${name}-${source.version}.tgz";
      inherit (source) hash;
    })
  sources;
  highcharts = sources.highcharts.version;
  chartkick = sources.chartkick.version;
  maplibre = sources.maplibre-gl.version;
in
  runCommand "larapaper-web-libraries" {
    passthru = {
      inherit sources;
      updateScript = updaters.mkScriptUpdater {
        pname = "larapaper-web-libraries";
        script = ./update.sh;
        extraRuntimeInputs = [python3];
      };
    };
    meta.platforms = lib.platforms.all;
  } ''
    mkdir -p "$out/js" highcharts chartkick maplibre
    tar -xf ${archives.highcharts} -C highcharts --strip-components=1
    tar -xf ${archives.chartkick} -C chartkick --strip-components=1
    tar -xf ${archives.maplibre-gl} -C maplibre --strip-components=1
    mkdir -p "$out/js/highcharts/${highcharts}" "$out/js/chartkick/${chartkick}" "$out/js/maplibre-gl/${maplibre}"
    cp highcharts/highcharts.js "$out/js/highcharts/${highcharts}/"
    cp highcharts/modules/pattern-fill.js "$out/js/highcharts/${highcharts}/"
    cp chartkick/dist/chartkick.js "$out/js/chartkick/${chartkick}/chartkick.min.js"
    cp maplibre/dist/maplibre-gl.{js,css} "$out/js/maplibre-gl/${maplibre}/"
    cp highcharts/{package.json,README.md} "$out/js/highcharts/${highcharts}/"
    cp chartkick/LICENSE.txt "$out/js/chartkick/${chartkick}/"
    cp maplibre/dist/LICENSE.txt "$out/js/maplibre-gl/${maplibre}/"
  ''
