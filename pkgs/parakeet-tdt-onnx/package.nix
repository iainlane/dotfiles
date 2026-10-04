# NVIDIA Parakeet TDT 0.6B v3 speech-recognition model, full-precision ONNX
# export by istupakov. The file set matches what `voxtype setup --download
# --model parakeet-tdt-0.6b-v3` fetches, so the output directory can be used
# directly as `programs.voxtype.model.path`.
{
  fetchurl,
  lib,
  stdenvNoCC,
  updaters,
  python3,
}: let
  source = lib.importJSON ./source.json;
  inherit (source) revision files;
in
  stdenvNoCC.mkDerivation {
    pname = "parakeet-tdt-onnx";
    inherit (source) version;

    srcs =
      lib.mapAttrsToList (
        name: hash:
          fetchurl {
            url = "https://huggingface.co/${source.repository}/resolve/${revision}/${name}";
            inherit name hash;
          }
      )
      files;

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
      pname = "parakeet-tdt-onnx";
      script = ./update.sh;
      extraRuntimeInputs = [python3];
    };

    meta = {
      description = "NVIDIA Parakeet TDT 0.6B v3 speech-recognition model, full-precision ONNX export";
      homepage = "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx";
      license = lib.licenses.cc-by-40;
      platforms = lib.platforms.all;
    };
  }
