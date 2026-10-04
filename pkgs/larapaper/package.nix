{
  lib,
  php84,
  fetchFromGitHub,
  fetchurl,
  applyPatches,
  buildNpmPackage,
  nodejs_24,
  autoPatchelfHook,
  stdenv,
  callPackage,
  trmnl-framework,
  updaters,
  gh,
  python3,
  nix-update,
}: let
  version = "0.43.1";
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
      rev = "f849ce24562bcc218fdc43246c9410f78b71ce91";
      hash = "sha256-QK6EWpxrp36aSoaF4wECUNcUVnrp3ZaZ7Vn2IB84Ae4=";
    };
    patches = [
      (fetchurl {
        url = "https://github.com/usetrmnl/larapaper/commit/f3d85b79a7176f81b59890247ba8948c7c99151d.patch";
        hash = "sha256-wneTUNwdLfWNMu3m8+N3f1Jd9c5KUtUr+fPrLC6rojY=";
      })
      (fetchurl {
        url = "https://github.com/usetrmnl/larapaper/commit/1f00bacd70b33b48256b14c090f66f3ccf9c8177.patch";
        hash = "sha256-3Aa+KduISR/i4TSnRdn+qj4Kd6gZl8BhACsnof2l+oc=";
      })
    ];
  };
  composerVendor = php.mkComposerVendor {
    pname = "larapaper";
    inherit version src;
    vendorHash = "sha256-O+bl2HWV6f0G+91LTOvh0pDYissx6zSZ295ODXJR4FA=";
    postBuild = ''
      find vendor -type d -name .git -prune -exec rm -rf {} +
    '';
  };
  frontend = buildNpmPackage {
    pname = "larapaper-frontend";
    inherit version src;
    nodejs = nodejs_24;
    npmDepsHash = "sha256-pMQHgRsALtNyo0dYdcVlhJMn4J8y48hqF+pFkz516p0=";
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
  webLibraries = callPackage ./web-libraries.nix {};
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
      cp -rs ${webLibraries}/js "$app/public/js"
      chmod u+w "$app/public/js"
      cp -rs ${trmnl-framework}/js/. "$app/public/js/"
    '';
    passthru = {
      inherit php frontend composerVendor webLibraries;
      updateScript = updaters.mkScriptUpdater {
        pname = "larapaper";
        script = ./update.sh;
        extraRuntimeInputs = [gh python3 nix-update];
      };
    };
    meta = {
      description = "Self-hosted TRMNL server with packaged rendering assets";
      homepage = "https://github.com/usetrmnl/larapaper";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  }
