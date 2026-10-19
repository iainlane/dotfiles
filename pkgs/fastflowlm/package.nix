{
  lib,
  stdenv,
  fetchFromGitHub,
  callPackage,
  updaters,
  gh,
  python3,
  cargo,
  autoPatchelfHook,
  cmake,
  makeBinaryWrapper,
  ninja,
  pkg-config,
  versionCheckHook,
  boost,
  curl,
  ffmpeg-headless,
  fftw,
  fftwFloat,
  fftwLongDouble,
  libdrm,
  libuuid,
  ncurses,
  readline,
  sentencepiece,
  xrt,
}: let
  tokenizers-cpp = callPackage ./tokenizers-cpp {};
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "fastflowlm";
    version = "1.0.9";

    __structuredAttrs = true;
    strictDeps = true;

    src = fetchFromGitHub {
      owner = "ROCm";
      repo = "FastFlowLM";
      tag = "v${finalAttrs.version}";
      hash = "sha256-ZxfIMPDQ4FCEsRqek+jULzYnCIw2hLY7b7+i6EhkSao=";
    };

    sourceRoot = "${finalAttrs.src.name}/src";

    patches = [./use-external-tokenizers.patch];

    nativeBuildInputs = [
      autoPatchelfHook
      cmake
      makeBinaryWrapper
      ninja
      pkg-config
    ];

    buildInputs = [
      boost
      curl
      ffmpeg-headless
      fftw
      fftwFloat
      fftwLongDouble
      libdrm
      libuuid
      ncurses
      readline
      sentencepiece
      (lib.getLib stdenv.cc.cc)
      xrt.xdna
    ];

    cmakeFlags = [
      (lib.cmakeFeature "FLM_VERSION" finalAttrs.version)
      (lib.cmakeFeature "NPU_VERSION" finalAttrs.version)
      (lib.cmakeFeature "TOKENIZERS_CPP_LIB_PATH" "${tokenizers-cpp}/lib/libtokenizers_cpp.a")
      (lib.cmakeFeature "TOKENIZERS_C_LIB_PATH" "${tokenizers-cpp.tokenizers-c}/lib/libtokenizers_c.a")
      (lib.cmakeFeature "TOKENIZERS_CPP_INCLUDE_PATH" "${tokenizers-cpp}/include")
    ];

    postInstall = ''
      install -Dm644 ${finalAttrs.src}/LICENSE_RUNTIME.txt ${finalAttrs.src}/LICENSE_BINARY.txt \
        -t $out/share/licenses/fastflowlm
    '';

    # Without XILINX_XRT, XRT looks for its driver plugins beside the shim in
    # the base `xrt` package, which does not contain the XDNA plugin.
    postFixup = ''
      wrapProgram $out/bin/flm \
        --set-default XILINX_XRT ${xrt.xdna}
    '';

    nativeInstallCheckInputs = [versionCheckHook];
    doInstallCheck = true;

    passthru = {
      inherit tokenizers-cpp;

      updateScript = updaters.mkScriptUpdater {
        pname = "fastflowlm";
        script = ./update.sh;
        extraRuntimeInputs = [gh python3 cargo];
      };
    };

    meta = {
      description = "LLM runtime for AMD XDNA 2 NPUs";
      homepage = "https://fastflowlm.com";
      downloadPage = "https://github.com/ROCm/FastFlowLM/releases";
      changelog = "https://github.com/ROCm/FastFlowLM/releases/tag/${finalAttrs.src.tag}";
      # The prebuilt NPU binaries cannot be modified.
      license = with lib.licenses; [
        mit
        unfree
      ];
      sourceProvenance = with lib.sourceTypes; [
        fromSource
        binaryNativeCode
        binaryFirmware
      ];
      platforms = ["x86_64-linux"];
      mainProgram = "flm";
    };
  })
