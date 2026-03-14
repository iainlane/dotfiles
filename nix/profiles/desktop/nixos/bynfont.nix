{
  lib,
  fetchFromGitHub,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "bynfont";
  version = "0-unstable-2024-06-02";

  src = fetchFromGitHub {
    owner = "bynux-gh";
    repo = "bynfont";
    rev = "f27183da0427acf332f0c3fc718c9cda9de75637";
    hash = "sha256:0wn32dj5bylyk4k2caas6cm9affjshb1rlj8yyn94b9gsl2s8wdx";
  };

  installPhase = ''
    runHook preInstall
    install -Dm444 bynfont.psfu.gz $out/share/consolefonts/bynfont.psfu.gz
    runHook postInstall
  '';

  meta = {
    description = "A modern bitmap font for Linux terminal";
    homepage = "https://github.com/bynux-gh/bynfont";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
