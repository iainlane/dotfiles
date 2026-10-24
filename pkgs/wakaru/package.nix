{
  lib,
  rustPlatform,
  fetchFromGitHub,
  updaters,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "wakaru";
  version = "1.14.0";

  src = fetchFromGitHub {
    owner = "pionxzh";
    repo = "wakaru";
    tag = "v${finalAttrs.version}";
    hash = "sha256-HdSrirk4VcWlifK4m97fJbyfXeIhLfzWRWQGPxAd0hI=";
  };

  cargoHash = "sha256-t3LS3nMihmHmRmJ014YkvXYynv4XwtQWn267GAWnLiE=";
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
