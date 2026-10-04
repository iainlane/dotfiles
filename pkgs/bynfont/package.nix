{
  lib,
  fetchFromGitHub,
  stdenvNoCC,
  updaters,
}:
stdenvNoCC.mkDerivation {
  pname = "bynfont";
  version = "2.1-unstable-2024-07-23";

  src = fetchFromGitHub {
    owner = "bynux-gh";
    repo = "bynfont";
    rev = "f27183da0427acf332f0c3fc718c9cda9de75637";
    hash = "sha256-vXGkBdUvLZKs90jSHBbU0jmVKjNaKSYmmZ76VWQTw3I=";
  };

  installPhase = ''
    runHook preInstall
    install -Dm444 bynfont.psfu.gz $out/share/consolefonts/bynfont.psfu.gz
    runHook postInstall
  '';

  passthru.updateScript = updaters.mkNixUpdateUpdater {
    attr = "bynfont";
    extraFlags = ["--version=branch=main" "--system" "aarch64-linux"];
  };

  meta = {
    description = "A modern bitmap font for Linux terminal";
    homepage = "https://github.com/bynux-gh/bynfont";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
