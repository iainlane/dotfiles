{
  fetchurl,
  lib,
  stdenvNoCC,
  updaters,
  python3,
}: let
  source = lib.importJSON ./source.json;
in
  stdenvNoCC.mkDerivation {
    pname = "parakeet-unified-onnx";
    inherit (source) version;

    srcs =
      lib.mapAttrsToList (
        name: hash:
          fetchurl {
            url = "https://huggingface.co/${source.repository}/resolve/${source.revision}/${name}";
            inherit name hash;
          }
      )
      source.files;

    dontUnpack = true;
    preferLocalBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      for src in $srcs; do
        ln -s "$src" "$out/$(stripHash "$src")"
      done

      runHook postInstall
    '';

    passthru.updateScript = updaters.mkScriptUpdater {
      pname = "parakeet-unified-onnx";
      script = builtins.toFile "update-parakeet-unified-onnx.sh" ''
        python3 ${../parakeet-tdt-onnx/update.py} "$@"
      '';
      extraRuntimeInputs = [python3];
    };

    meta = {
      description = "NVIDIA Parakeet Unified English 0.6B model for streaming speech recognition";
      homepage = "https://huggingface.co/${source.repository}";
      license = lib.licenses.cc-by-40;
      platforms = lib.platforms.all;
    };
  }
