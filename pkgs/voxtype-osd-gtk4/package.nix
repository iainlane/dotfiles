# nixpkgs packages the voxtype daemon but not the on-screen-display
# frontends, which upstream only ships through its flake. Keep the version in
# step with pkgs.voxtype-onnx: the daemon's `voxtype-osd` launcher and this
# frontend communicate over a socket whose protocol is not stable across
# versions.
{
  alsa-lib,
  cmake,
  git,
  gtk4-layer-shell,
  openssl,
  lib,
  llvmPackages,
  pkg-config,
  rustPlatform,
  voxtype-onnx,
  wrapGAppsHook4,
}:
rustPlatform.buildRustPackage {
  pname = "voxtype-osd-gtk4";
  inherit (voxtype-onnx) version src cargoDeps;

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

  meta = {
    description = "GTK4 on-screen display frontend for voxtype";
    homepage = "https://voxtype.io";
    license = lib.licenses.mit;
    mainProgram = "voxtype-osd-gtk4";
    platforms = lib.platforms.linux;
  };
}
