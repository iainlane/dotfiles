# To update: nix run .#update-eitype
{
  fetchFromGitHub,
  lib,
  libxkbcommon,
  pkg-config,
  rustPlatform,
  updaters,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "eitype";
  version = "0.2.2";

  src = fetchFromGitHub {
    owner = "Adam-D-Lewis";
    repo = "eitype";
    tag = finalAttrs.version;
    hash = "sha256-s5g6METDi8/jPEwZursorYWN8X96VlyVPtd8dCCVIlw=";
  };

  cargoHash = "sha256-k0JU3Y83aPHgQpyiG6DXxBzdYSMOmH42kPCxXWtNtkQ=";

  nativeBuildInputs = [pkg-config];
  buildInputs = [libxkbcommon];

  passthru.updateScript = updaters.mkNixUpdateUpdater {attr = "eitype";};

  meta = {
    description = "CLI tool for typing text via the emulated-input (EI) protocol on Wayland";
    homepage = "https://github.com/Adam-D-Lewis/eitype";
    license = lib.licenses.asl20;
    mainProgram = "eitype";
    platforms = lib.platforms.linux;
  };
})
