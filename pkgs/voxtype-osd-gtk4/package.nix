# nixpkgs packages the voxtype daemon but not the on-screen-display frontends,
# which upstream only ships through its flake. The daemon's `voxtype-osd`
# launcher and this frontend communicate over a socket whose protocol is not
# stable across versions, so this package takes its version, source and
# vendored crates from `voxtype-onnx` and needs no updater of its own:
# `nix run .#update-voxtype` moves both.
{
  alsa-lib,
  cmake,
  gitMinimal,
  gtk4-layer-shell,
  lib,
  libclang,
  openssl,
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
    gitMinimal
    pkg-config
    wrapGAppsHook4
  ];

  buildInputs = [
    alsa-lib
    gtk4-layer-shell
    openssl
  ];

  env.LIBCLANG_PATH = "${lib.getLib libclang}/lib";

  meta = {
    description = "GTK4 on-screen display frontend for voxtype";
    homepage = "https://voxtype.io";
    license = lib.licenses.mit;
    mainProgram = "voxtype-osd-gtk4";
    platforms = lib.platforms.linux;
  };
}
