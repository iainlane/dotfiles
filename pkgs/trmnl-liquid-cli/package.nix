{
  lib,
  stdenvNoCC,
  bundlerEnv,
  ruby_3_4,
  makeWrapper,
  callPackage,
  updaters,
  python3,
  bundix,
}: let
  source = lib.importJSON ./source.json;
  gems = bundlerEnv {
    name = "trmnl-liquid-cli-gems";
    ruby = ruby_3_4;
    gemdir = ./.;
  };
in
  stdenvNoCC.mkDerivation {
    pname = "trmnl-liquid-cli";
    version = lib.last (lib.splitString ":" source.image);
    src = ./trmnl-liquid-cli.rb;
    dontUnpack = true;
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      install -Dm644 "$src" "$out/libexec/trmnl-liquid-cli.rb"
      makeWrapper ${gems.wrappedRuby}/bin/ruby "$out/bin/trmnl-liquid-cli" \
        --add-flags "$out/libexec/trmnl-liquid-cli.rb"
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      printf '{{ value | upcase }}' > template.liquid
      test "$("$out/bin/trmnl-liquid-cli" --input template.liquid --context '{"value":"local"}')" = LOCAL
    '';
    passthru = {
      inherit gems;
      extractSource = callPackage ./extract-source.nix {};
      updateScript = updaters.mkScriptUpdater {
        pname = "trmnl-liquid-cli";
        script = ./update.sh;
        extraRuntimeInputs = [python3 bundix];
      };
    };
    meta = {
      description = "TRMNL Liquid renderer rebuilt from the published CLI source";
      platforms = lib.platforms.all;
      mainProgram = "trmnl-liquid-cli";
    };
  }
