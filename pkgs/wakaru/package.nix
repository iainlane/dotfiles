{
  lib,
  rustPlatform,
  fetchFromGitHub,
  updaters,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "wakaru";
  version = "1.15.0";

  src = fetchFromGitHub {
    owner = "pionxzh";
    repo = "wakaru";
    tag = "v${finalAttrs.version}";
    hash = "sha256-v6RGCKj7W1cmLHh1gPfLEZAkD0TUU1z6PnZa+fDXexA=";
  };

  cargoHash = "sha256-AOgkxrRCvtTbe+2tWf6G5UV+bwo1Q7r7z7HXz5MyqNg=";
  cargoBuildFlags = ["--package" "wakaru-cli"];
  cargoTestFlags = ["--package" "wakaru-cli"];

  passthru.updateScript = updaters.mkNixUpdateUpdater {attr = "wakaru";};

  meta = {
    description = "JavaScript decompiler and bundle splitter";
    homepage = "https://github.com/pionxzh/wakaru";
    license = lib.licenses.asl20;
    mainProgram = "wakaru";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
