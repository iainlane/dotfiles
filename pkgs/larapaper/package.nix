{
  lib,
  inputs,
  pkgs,
  php84,
  fetchFromGitHub,
  applyPatches,
  buildNpmPackage,
  nodejs_24,
  autoPatchelfHook,
  stdenv,
  larapaper-highcharts,
  larapaper-chartkick,
  larapaper-maplibre-gl,
  trmnl-framework,
  updaters,
  gh,
  python3,
  nix-update,
}: let
  version = "0.45.1";
  php = php84.buildEnv {
    extensions = {
      enabled,
      all,
    }:
      enabled ++ [all.imagick all.zip all.intl all.gd all.bcmath];
    extraConfig = ''
      memory_limit = 256M
      upload_max_filesize = 100M
      post_max_size = 100M
    '';
  };
  src = applyPatches {
    src = fetchFromGitHub {
      owner = "usetrmnl";
      repo = "larapaper";
      rev = "883dd810a5331da6ffa554cf79f6e3d48b4822d9";
      hash = "sha256-+0yA2JZkHd0v7JjPsO48F7/9+qJcfwMlKsDRIST7mWg=";
    };
    patches = [./recipe-chart-assets.patch];
  };
  composerVendor = php.mkComposerVendor {
    pname = "larapaper";
    inherit version src;
    vendorHash = "sha256-gR2Qfjvos3uu31uRr5lwog0xkp892QhQfjoU0VGBQSw=";
    postBuild = ''
      find vendor -type d -name .git -prune -exec rm -rf {} +
    '';
  };
  frontend = buildNpmPackage {
    pname = "larapaper-frontend";
    inherit version src;
    nodejs = nodejs_24;
    npmDepsHash = "sha256-Xx4O7EDRalfBhuYgGIK/zPKRaWIYX/j9Uz1NKtuRNxU=";
    env.PUPPETEER_SKIP_DOWNLOAD = "true";
    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
    preBuild = ''
      cp -r ${composerVendor}/vendor .
      ${lib.optionalString stdenv.hostPlatform.isLinux "autoPatchelf node_modules"}
    '';
    installPhase = ''
      mkdir -p "$out"
      cp -r public/build node_modules "$out/"
    '';
  };
  webLibraries = {
    highcharts = larapaper-highcharts;
    chartkick = larapaper-chartkick;
    maplibre-gl = larapaper-maplibre-gl;
  };
in
  php.buildComposerProject2 {
    pname = "larapaper";
    inherit version src composerVendor;
    env.COMPOSER_DISABLE_NETWORK = "1";
    postInstall = ''
        app="$out/share/php/larapaper"
        rm -rf "$app/.env.example" "$app/storage" "$app/bootstrap/cache" "$app/database/storage"
        ln -s /var/lib/larapaper/storage "$app/storage"
        ln -s /var/lib/larapaper/cache "$app/bootstrap/cache"
        ln -s /var/lib/larapaper/database "$app/database/storage"
        ln -s /var/lib/larapaper/storage/app/public "$app/public/storage"
        ln -s ${frontend}/build "$app/public/build"
        ln -s ${frontend}/node_modules "$app/node_modules"
        for directory in css fonts images; do
          mkdir -p "$app/public/$directory"
          cp -rs ${trmnl-framework}/"$directory"/. "$app/public/$directory/"
        done
      mkdir -p "$app/public/js"
      ${lib.concatMapStringsSep "\n" (library: ''cp -rs ${library}/js/. "$app/public/js/"'') (lib.attrValues webLibraries)}
      cp -rs ${trmnl-framework}/js/. "$app/public/js/"
    '';
    passthru = {
      inherit php frontend composerVendor webLibraries;
      updateScript = updaters.mkScriptUpdater {
        pname = "larapaper";
        script = ./update.sh;
        extraRuntimeInputs = [gh python3 nix-update];
      };
      tests = {
        php =
          ((import ./php-check.nix {inherit inputs lib;}) {
            inherit pkgs;
            system = pkgs.stdenv.hostPlatform.system;
          }).larapaper-php;
        source = src;
        updater = updaters.mkScriptUpdaterTest {
          pname = "larapaper";
          script = ./update.sh;
          test = ./update.test.sh;
          extraInputs = [python3];
        };
      };
    };
    meta = {
      description = "Self-hosted TRMNL server with packaged rendering assets";
      homepage = "https://github.com/usetrmnl/larapaper";
      license = lib.licenses.mit;
    };
  }
