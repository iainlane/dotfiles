{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  nix-update-script,
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
  version = "0.7.5";
  infoPlist = builtins.toFile "Info.plist" (
    builtins.replaceStrings ["@version@"] [version] (builtins.readFile ./Info.plist)
  );
in
  rustPlatform.buildRustPackage {
    pname = "voxtype";
    inherit version;

    src = fetchFromGitHub {
      owner = "peteonrails";
      repo = "voxtype";
      tag = "v${version}";
      hash = "sha256-zsOG1mBTXN4gdsTb1pUPKXATfhV5ZjgEsIUk07asaGo=";
    };

    cargoHash = "sha256-YK5xZWPo7KAeWZeuMxNxHA3k6RR/MT2MIfEPcgMND00=";

    buildFeatures =
      lib.optionals stdenv.hostPlatform.isDarwin ["gpu-metal"]
      ++ lib.optionals vulkanSupport ["gpu-vulkan"]
      ++ lib.optionals (onnxSupport && stdenv.hostPlatform.isDarwin) ["parakeet-coreml"]
      ++ lib.optionals (onnxSupport && stdenv.hostPlatform.isLinux) [
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
      ++ lib.optionals onnxSupport [onnxruntime];

    env =
      {
        LIBCLANG_PATH = "${lib.getLib libclang}/lib";
        RUSTFLAGS = lib.optionalString (
          stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64
        ) "-C target-cpu=x86-64-v3";
      }
      // lib.optionalAttrs (onnxSupport && stdenv.hostPlatform.isDarwin) {
        ORT_PREFER_DYNAMIC_LINK = "1";
        ORT_STRATEGY = "system";
      };

    preBuild =
      ''
        export CMAKE_BUILD_PARALLEL_LEVEL=$NIX_BUILD_CORES
      ''
      + lib.optionalString vulkanSupport ''
        export VULKAN_SDK="${shaderc.bin}"
      ''
      + lib.optionalString onnxSupport ''
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

        ${lib.optionalString onnxSupport ''
          wrapProgram "$out/bin/voxtype" \
            --prefix DYLD_FALLBACK_LIBRARY_PATH : "${lib.getLib onnxruntime}/lib"
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
