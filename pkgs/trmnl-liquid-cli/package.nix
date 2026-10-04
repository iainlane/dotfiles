{
  lib,
  stdenvNoCC,
  bundlerEnv,
  ruby_3_4,
  makeWrapper,
}: let
  gems = bundlerEnv {
    name = "trmnl-liquid-cli-gems";
    ruby = ruby_3_4;
    gemdir = ./.;
  };
in
  stdenvNoCC.mkDerivation {
    pname = "trmnl-liquid-cli";
    version = "0.2.0";
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
    passthru = {inherit gems;};
    meta = {
      description = "TRMNL Liquid renderer rebuilt from the published CLI source";
      platforms = lib.platforms.all;
      mainProgram = "trmnl-liquid-cli";
    };
  }
