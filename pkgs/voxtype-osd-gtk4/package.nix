# To update: nix run .#update-voxtype-osd-gtk4
#
# nixpkgs packages the voxtype daemon but not the on-screen-display
# frontends, which upstream only ships through its flake. Keep the version in
# step with pkgs.voxtype-onnx: the daemon's `voxtype-osd` launcher and this
# frontend communicate over a socket whose protocol is not stable across
# versions.
{
  alsa-lib,
  cmake,
  fetchFromGitHub,
  git,
  gtk4-layer-shell,
  openssl,
  lib,
  llvmPackages,
  pkg-config,
  rustPlatform,
  updaters,
  voxtype-onnx,
  wrapGAppsHook4,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "voxtype-osd-gtk4";
  version = "0.7.5";

  src = fetchFromGitHub {
    owner = "peteonrails";
    repo = "voxtype";
    tag = "v${finalAttrs.version}";
    hash = "sha256-zsOG1mBTXN4gdsTb1pUPKXATfhV5ZjgEsIUk07asaGo=";
  };

  cargoHash = "sha256-YK5xZWPo7KAeWZeuMxNxHA3k6RR/MT2MIfEPcgMND00=";

  buildFeatures = ["osd-gtk4"];
  cargoBuildFlags = ["--bin" "voxtype-osd-gtk4"];

  # The workspace's test suite covers the daemon, which this package does not
  # ship.
  doCheck = false;

  nativeBuildInputs = [
    cmake
    git
    pkg-config
    wrapGAppsHook4
  ];

  buildInputs = [
    alsa-lib
    gtk4-layer-shell
    openssl
  ];

  env.LIBCLANG_PATH = "${lib.getLib llvmPackages.libclang}/lib";

  # Pin the update target to the daemon's nixpkgs version so this package
  # stays in step with pkgs.voxtype-onnx.
  passthru.updateScript = updaters.mkNixUpdateUpdater {
    attr = "voxtype-osd-gtk4";
    extraFlags = ["--version" voxtype-onnx.version];
  };

  meta = {
    description = "GTK4 on-screen display frontend for voxtype";
    homepage = "https://voxtype.io";
    license = lib.licenses.mit;
    mainProgram = "voxtype-osd-gtk4";
    platforms = lib.platforms.linux;
  };
})
