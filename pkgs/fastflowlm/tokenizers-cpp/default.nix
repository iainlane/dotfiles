{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  cmake,
  pkg-config,
  msgpack-cxx,
  sentencepiece,
}: let
  version = "0.1.1-unstable-2026-02-20";

  src = fetchFromGitHub {
    owner = "mlc-ai";
    repo = "tokenizers-cpp";
    rev = "acbdc5a27ae01ba74cda756f94da698d40f11dfe";
    hash = "sha256-gJ/Xx1el3L9cUiQwGfecvGY3dYVaGTPsS+Ii7dSNzME=";
  };

  tokenizers-c = rustPlatform.buildRustPackage {
    pname = "tokenizers-c";
    inherit version src;

    __structuredAttrs = true;

    sourceRoot = "${src.name}/rust";

    cargoLock.lockFile = ./Cargo.lock;

    postPatch = ''
      ln -s ${./Cargo.lock} Cargo.lock
    '';

    meta = {
      description = "C bindings for the Hugging Face tokenizers library";
      homepage = "https://github.com/mlc-ai/tokenizers-cpp";
      license = lib.licenses.asl20;
      platforms = lib.platforms.unix;
    };
  };
in
  stdenv.mkDerivation {
    pname = "tokenizers-cpp";
    inherit version src;

    __structuredAttrs = true;
    strictDeps = true;

    patches = [./use-system-libs.patch];

    nativeBuildInputs = [
      cmake
      pkg-config
    ];

    buildInputs = [
      msgpack-cxx
      sentencepiece
      tokenizers-c
    ];

    cmakeFlags = [
      (lib.cmakeFeature "TOKENIZERS_RUST_LIB_PATH" "${lib.getLib tokenizers-c}/lib/libtokenizers_c.a")
    ];

    installPhase = ''
      runHook preInstall

      install -Dm644 libtokenizers_cpp.a -t $out/lib
      mkdir -p $out/include
      cp -r ../include/. $out/include/

      runHook postInstall
    '';

    passthru = {inherit tokenizers-c;};

    meta = {
      description = "C++ wrapper for the Hugging Face and SentencePiece tokenizers";
      homepage = "https://github.com/mlc-ai/tokenizers-cpp";
      license = lib.licenses.asl20;
      platforms = lib.platforms.unix;
    };
  }
