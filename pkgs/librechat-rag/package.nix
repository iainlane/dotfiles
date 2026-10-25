{
  autoPatchelfHook,
  callPackage,
  cacert,
  fetchFromGitHub,
  file,
  lib,
  libGL,
  glib,
  makeWrapper,
  pandoc,
  poppler-utils,
  pyproject-build-systems,
  pyproject-nix,
  python312,
  stdenv,
  stdenvNoCC,
  tbb,
  tesseract,
  uv2nix,
}: let
  workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};

  base = callPackage pyproject-nix.build.packages {python = python312;};

  pythonSet = base.overrideScope (lib.composeManyExtensions [
    pyproject-build-systems.overlays.wheel
    (workspace.mkPyprojectOverlay {sourcePreference = "wheel";})
    (final: prev:
      {
        langdetect = prev.langdetect.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ final.resolveBuildSystem {setuptools = [];};
        });

        numba = prev.numba.overrideAttrs (old: {
          buildInputs = (old.buildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [tbb];
        });
      }
      // lib.genAttrs ["opencv-python-headless" "onnxruntime"] (name:
        prev.${name}.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
          buildInputs = (old.buildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [libGL glib stdenv.cc.cc.lib];
        })))
  ]);

  environment = pythonSet.mkVirtualEnv "librechat-rag-environment" workspace.deps.default;
in
  stdenvNoCC.mkDerivation {
    pname = "librechat-rag";
    version = "2026-10-25";
    src = fetchFromGitHub {
      owner = "LibreChat-AI";
      repo = "rag-api";
      rev = "c4e5cbf79fcece1df9adfff5dfed983a5990ca9f";
      hash = "sha256-iPDUR0LkexWkfffiSki6KL4LCavG+uUljT14Rz6x8g8=";
    };
    nativeBuildInputs = [makeWrapper];
    dontBuild = true;
    doInstallCheck = true;

    installCheckPhase = ''
      runHook preInstallCheck
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      ${environment}/bin/python -c 'import cv2, numpy, numba, rapidocr_onnxruntime, asyncpg, psycopg2, langchain_ollama'
      runHook postInstallCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/librechat-rag" "$out/bin"
      cp -r app main.py "$out/lib/librechat-rag/"
      makeWrapper ${environment}/bin/uvicorn "$out/bin/librechat-rag" \
        --add-flags 'main:app --host 127.0.0.1 --port 3180' \
        --set-default SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt \
        --prefix PYTHONPATH : "$out/lib/librechat-rag" \
        --prefix PATH : ${lib.makeBinPath [pandoc poppler-utils tesseract]} \
        --prefix DYLD_LIBRARY_PATH : ${lib.makeLibraryPath [file]} \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [file]}
      runHook postInstall
    '';

    passthru = {
      updateScript = null;
      inherit environment;
    };

    meta = {
      description = "LibreChat document ingestion and semantic retrieval service";
      homepage = "https://github.com/LibreChat-AI/rag-api";
      license = lib.licenses.mit;
      mainProgram = "librechat-rag";
      platforms = lib.platforms.unix;
    };
  }
