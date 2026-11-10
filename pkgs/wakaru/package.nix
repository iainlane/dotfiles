{
  lib,
  rustPlatform,
  fetchFromGitHub,
  updaters,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "wakaru";
  version = "1.16.0";

  src = fetchFromGitHub {
    owner = "pionxzh";
    repo = "wakaru";
    tag = "v${finalAttrs.version}";
    hash = "sha256-lo/EJC8BeU+C3KB5M1/3L68a4iUbW6w05ImsZHllsZo=";
  };

  cargoHash = "sha256-j75BEvh1ig5kndB9Kd21m9OFaNokmB/LI1QQitL5z/E=";
  cargoBuildFlags = ["--package" "wakaru-cli"];
  cargoTestFlags = ["--package" "wakaru-cli"];

  passthru.updateScript = updaters.mkNixUpdateUpdater {
    refresh = true;
    attr = "wakaru";
  };

  meta = {
    description = "JavaScript decompiler and bundle splitter";
    homepage = "https://github.com/pionxzh/wakaru";
    license = lib.licenses.asl20;
    mainProgram = "wakaru";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
