{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
  dart-sass,
  updaters,
  gh,
}: let
  source = lib.importJSON ./source.json;
  fetchRelease = release:
    fetchFromGitHub {
      owner = "usetrmnl";
      repo = "trmnl-framework";
      tag = "v${release.version}";
      inherit (release) hash;
    };
  legacySources = map fetchRelease source.legacy;
in
  stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "trmnl-framework";
    inherit (source) version;
    src = fetchRelease source;
    patches = [
      (fetchurl {
        url = "https://github.com/usetrmnl/trmnl-framework/commit/2159940809f7d9e68401c34ce315a66027bc09a7.patch";
        hash = "sha256-awceJWxHJdHcV48nsJSvTh2nY8S7t98Ooa7ifaGmRoY=";
      })
    ];
    nativeBuildInputs = [dart-sass];
    buildPhase = ''
      runHook preBuild
      SASS_BIN=${lib.getExe dart-sass} bash bin/build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      ${lib.concatMapStringsSep "\n" (legacy: ''
          cp -r --no-preserve=mode ${legacy}/public/{css,fonts,images} "$out/"
        '')
        legacySources}
      cp -r public/{css,fonts,images} "$out/"
      mkdir -p "$out/css/${finalAttrs.version}/themes" "$out/js/${finalAttrs.version}"
      cp dist/plugins.css "$out/css/${finalAttrs.version}/plugins.css"
      cp dist/themes/*.css "$out/css/${finalAttrs.version}/themes/"
      cp dist/js/plugins.js "$out/js/${finalAttrs.version}/plugins.js"
      runHook postInstall
    '';
    passthru.updateScript = updaters.mkScriptUpdater {
      pname = "trmnl-framework";
      script = ./update.sh;
      extraRuntimeInputs = [gh];
    };
    meta = {
      description = "TRMNL framework assets with the scaled table overflow fix";
      homepage = "https://github.com/usetrmnl/trmnl-framework";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  })
