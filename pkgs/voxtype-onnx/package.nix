# To update: nix run .#update-voxtype-onnx
#
# Built from the fork's `dotfiles` branch, which carries the XDG
# GlobalShortcuts portal backend and spoken-punctuation handling for
# auto-punctuating engines, both proposed upstream (peteonrails/voxtype#616
# and #617). nixpkgs packages voxtype for Linux only; this derivation also
# builds the same ONNX variant for darwin, where upstream's support is the
# Homebrew cask built from the same crate. Drop this package for the nixpkgs
# one when a release containing both changes lands there.
{
  alsa-lib,
  dotool,
  fetchFromGitHub,
  installShellFiles,
  lib,
  libnotify,
  makeBinaryWrapper,
  cmake,
  git,
  llvmPackages,
  onnxruntime,
  openssl,
  pkg-config,
  rustPlatform,
  stdenv,
  updaters,
  versionCheckHook,
  which,
  wl-clipboard,
  wtype,
  xclip,
  xdotool,
}: let
  onnxFeatures = [
    "parakeet-load-dynamic"
    "moonshine"
    "sensevoice"
    "paraformer"
    "dolphin"
    "omnilingual"
  ];

  libExt =
    if stdenv.hostPlatform.isDarwin
    then "dylib"
    else "so";

  linuxRuntimeDeps = [
    dotool
    wl-clipboard
    wtype
    xclip
    xdotool
  ];
in
  rustPlatform.buildRustPackage {
    pname = "voxtype-onnx";
    version = "0.7.5";

    src = fetchFromGitHub {
      owner = "iainlane";
      repo = "voxtype";
      rev = "a8d7fc84da4076d05ddb94402e3968ab88902127";
      hash = "sha256-/ZwHViv+Q1Dg+gNeVhj6l7ZH7pcgFxL3bRIOqep8C0c=";
    };

    cargoHash = "sha256-LpU7H7sdnGRFRfejSboe4+AdsAbrqgq5Apit/S7vFxo=";

    buildFeatures = onnxFeatures;

    nativeBuildInputs = [
      cmake
      git
      installShellFiles
      makeBinaryWrapper
      pkg-config
    ];

    buildInputs =
      [
        onnxruntime
        openssl
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [alsa-lib];

    env = {
      LIBCLANG_PATH = "${lib.getLib llvmPackages.libclang}/lib";
      ORT_LIB_LOCATION = "${lib.getLib onnxruntime}/lib";
    };

    # whisper.cpp's cmake needs the parallelism hint inside the sandbox.
    preBuild = ''
      export CMAKE_BUILD_PARALLEL_LEVEL=$NIX_BUILD_CORES
    '';

    postInstall =
      ''
        install -Dm644 config/default.toml \
          $out/share/voxtype/default-config.toml

        installShellCompletion packaging/completions/voxtype.{bash,zsh,fish}

        wrapProgram $out/bin/voxtype \
          --prefix PATH : ${lib.makeBinPath (
          [which]
          ++ lib.optionals stdenv.hostPlatform.isLinux ([libnotify] ++ linuxRuntimeDeps)
        )} \
          --set ORT_DYLIB_PATH "${lib.getLib onnxruntime}/lib/libonnxruntime.${libExt}" \
          --prefix LD_LIBRARY_PATH : "${lib.getLib onnxruntime}/lib"
      ''
      + lib.optionalString stdenv.hostPlatform.isLinux ''
        # The portal backend resolves the application identity through this
        # desktop entry.
        install -Dm644 packaging/io.voxtype.Voxtype.desktop \
          $out/share/applications/io.voxtype.Voxtype.desktop
      '';

    nativeInstallCheckInputs = [versionCheckHook];
    doInstallCheck = true;

    passthru.updateScript = updaters.mkNixUpdateUpdater {
      attr = "voxtype-onnx";
      extraFlags = ["--version" "branch=dotfiles"];
    };

    meta = {
      description = "Voice-to-text with push-to-talk, ONNX engines";
      homepage = "https://voxtype.io";
      license = lib.licenses.mit;
      mainProgram = "voxtype";
      platforms = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    };
  }
