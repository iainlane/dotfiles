{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  fetchurl,
  nix-update-script,
  stdenvNoCC,
  versionCheckHook,
  clang,
  cmake,
  gitMinimal,
  installShellFiles,
  libclang,
  makeBinaryWrapper,
  pkg-config,
  alsa-lib,
  dotool,
  libnotify,
  openssl,
  pciutils,
  wl-clipboard,
  wtype,
  which,
  xclip,
  xdotool,
  xz,
  installManPages ? stdenv.buildPlatform.canExecute stdenv.hostPlatform,
  installShellCompletions ? stdenv.buildPlatform.canExecute stdenv.hostPlatform,
  vulkanSupport ? false,
  shaderc,
  vulkan-headers,
  vulkan-loader,
  onnxSupport ? false,
  onnxruntime,
  waylandSupport ? stdenv.hostPlatform.isLinux,
  waylandRuntimePackages ? [
    dotool
    wl-clipboard
    wtype
  ],
  x11Support ? stdenv.hostPlatform.isLinux,
  x11RuntimePackages ? [
    xclip
    xdotool
  ],
}: let
  version = "1.0.1";
  revision = "2009408d6244a2d4162feff798b07f1173dc4f08";
  webgpuRuntimeHash = "e7271056b10dc2fec4b1bcc5bb9ac28a5f288de0a1f9c24c389c95566a487549";
  webgpuRuntime = stdenvNoCC.mkDerivation {
    pname = "onnxruntime-webgpu";
    version = "1.24.2";

    src = fetchurl {
      url = "https://cdn.pyke.io/0/pyke:ort-rs/ms@1.24.2/aarch64-apple-darwin+wgpu.tar.lzma2";
      hash = "sha256-5ycQVrENwv7EsbzFu5rCil8ojeCh+cJMOJyVVmpIdUk=";
    };

    nativeBuildInputs = [xz];
    dontUnpack = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/lib" "$out/dfbin/aarch64-apple-darwin"
      xz --format=raw --lzma2=dict=64MiB --decompress --stdout "$src" \
        | tar -xf - -C "$out/lib"
      ln -s "$out/lib" \
        "$out/dfbin/aarch64-apple-darwin/${webgpuRuntimeHash}"

      runHook postInstall
    '';
  };
  dynamicOnnxSupport = onnxSupport && stdenv.hostPlatform.isLinux;
  webgpuOnnxSupport = onnxSupport && stdenv.hostPlatform.isDarwin;
  infoPlist = builtins.toFile "Info.plist" (
    builtins.replaceStrings ["@version@"] [version] (builtins.readFile ./Info.plist)
  );
in
  rustPlatform.buildRustPackage {
    pname = "voxtype";
    inherit version;

    src = fetchFromGitHub {
      owner = "iainlane";
      repo = "voxtype";
      rev = revision;
      hash = "sha256-wrjWDWCHvI7tcrNDjVTrCVwvJfyEGHNUwLUROra0Zws=";
    };

    cargoHash = "sha256-fTYAhz3TVDJGRQZbYunws6lIymvbJBRMCEcI7a/fyT4=";

    checkFlags = lib.optionals stdenv.hostPlatform.isDarwin [
      "--skip=setup::binary::tests::running_variant_reads_the_live_process_not_the_symlink"
    ];

    buildFeatures =
      lib.optionals stdenv.hostPlatform.isDarwin ["gpu-metal"]
      ++ lib.optionals vulkanSupport ["gpu-vulkan"]
      ++ lib.optionals webgpuOnnxSupport ["parakeet-webgpu"]
      ++ lib.optionals dynamicOnnxSupport [
        "parakeet-load-dynamic"
        "moonshine"
        "sensevoice"
        "paraformer"
        "dolphin"
        "omnilingual"
      ];

    nativeBuildInputs =
      [
        clang
        cmake
        gitMinimal
        installShellFiles
        makeBinaryWrapper
        pkg-config
      ]
      ++ lib.optionals vulkanSupport [
        shaderc
        vulkan-headers
        vulkan-loader
      ];

    buildInputs =
      [openssl]
      ++ lib.optionals stdenv.hostPlatform.isLinux [alsa-lib]
      ++ lib.optionals vulkanSupport [
        vulkan-headers
        vulkan-loader
      ]
      ++ lib.optionals dynamicOnnxSupport [onnxruntime]
      ++ lib.optionals webgpuOnnxSupport [webgpuRuntime];

    env =
      {
        LIBCLANG_PATH = "${lib.getLib libclang}/lib";
        RUSTFLAGS = lib.optionalString (
          stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64
        ) "-C target-cpu=x86-64-v3";
      }
      // lib.optionalAttrs webgpuOnnxSupport {
        ORT_CACHE_DIR = webgpuRuntime;
      };

    preBuild =
      ''
        export CMAKE_BUILD_PARALLEL_LEVEL=$NIX_BUILD_CORES
      ''
      + lib.optionalString vulkanSupport ''
        export VULKAN_SDK="${shaderc.bin}"
      ''
      + lib.optionalString dynamicOnnxSupport ''
        export ORT_LIB_LOCATION="${lib.getLib onnxruntime}/lib"
      '';

    postInstall =
      ''
        install -Dm644 config/default.toml \
          "$out/share/voxtype/default-config.toml"
      ''
      + lib.optionalString stdenv.hostPlatform.isLinux ''
        wrapProgram "$out/bin/voxtype" \
          --prefix PATH : ${
          (lib.makeBinPath (
            [
              libnotify
              which
            ]
            ++ lib.optionals vulkanSupport [pciutils]
            ++ lib.optionals waylandSupport waylandRuntimePackages
            ++ lib.optionals x11Support x11RuntimePackages
          ))
          + lib.optionalString onnxSupport " \\"
        }
          ${lib.optionalString onnxSupport ''
          --set ORT_DYLIB_PATH "${lib.getLib onnxruntime}/lib/libonnxruntime.so" \
          --prefix LD_LIBRARY_PATH : "${lib.getLib onnxruntime}/lib"
        ''}
      ''
      + lib.optionalString stdenv.hostPlatform.isDarwin ''
        app="$out/Applications/Voxtype.app/Contents"
        install -Dm755 "$out/bin/voxtype" "$app/MacOS/voxtype-bin"
        install -Dm644 ${infoPlist} "$app/Info.plist"
        install -Dm644 assets/icon.png "$app/Resources/AppIcon.png"

        ${lib.optionalString webgpuOnnxSupport ''
          install -Dm755 ${webgpuRuntime}/lib/libwebgpu_dawn.dylib \
            "$out/lib/libwebgpu_dawn.dylib"
          install_name_tool -add_rpath "$out/lib" "$out/bin/voxtype"

          install -Dm755 ${webgpuRuntime}/lib/libwebgpu_dawn.dylib \
            "$app/Frameworks/libwebgpu_dawn.dylib"
          install_name_tool -add_rpath '@executable_path/../Frameworks' \
            "$app/MacOS/voxtype-bin"
        ''}
      ''
      + lib.optionalString installManPages ''
        installManPage target/debug/build/voxtype-*/out/man/*
      ''
      + lib.optionalString installShellCompletions ''
        installShellCompletion packaging/completions/voxtype.{bash,zsh,fish}
      '';

    nativeInstallCheckInputs = [versionCheckHook];
    doInstallCheck = true;

    passthru.update-script = nix-update-script {};

    meta = {
      description = "Voice-to-text with push-to-talk";
      longDescription = ''
        Voxtype is a push-to-talk voice-to-text daemon for Linux and macOS.
        Hold a hotkey while speaking, then release it to transcribe and type
        the text at the cursor position.
      '';
      homepage = "https://voxtype.io";
      downloadPage = "https://voxtype.io/download/";
      changelog = "https://github.com/peteonrails/voxtype/releases/tag/v${version}";
      license = lib.licenses.mit;
      maintainers = with lib.maintainers; [DuskyElf];
      platforms = lib.platforms.linux ++ ["aarch64-darwin"];
      mainProgram = "voxtype";
    };
  }
