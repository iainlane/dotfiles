# NVIDIA Parakeet TDT 0.6B v3 speech-recognition model, int8 ONNX export by
# istupakov. The file set matches what `voxtype setup --download --model
# parakeet-tdt-0.6b-v3-int8` fetches, so the output directory can be used
# directly as `programs.voxtype.model.path`.
{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  revision = "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce";

  files = {
    "encoder-model.int8.onnx" = "sha256-YTnS+n4bCGCXsnfHFJcl7bq4nMfHrmSyPHQb5AVa/wk=";
    "decoder_joint-model.int8.onnx" = "sha256-7qdIPuPRowN12u3I7YPjlgyRsJiBISeg2Z0ciXdmenA=";
    "vocab.txt" = "sha256-1YVEZ56kvGrFY9H1Ret9R0vWz6Rn8KbiwdwcfTfjw10=";
    "config.json" = "sha256-ZmkDx2uXmMrywhCv1PbNYLCKjb+YAOyNejvA0hSKxGY=";
  };
in
  stdenvNoCC.mkDerivation {
    pname = "parakeet-tdt-onnx";
    version = "0.6b-v3-int8";

    srcs =
      lib.mapAttrsToList (
        name: hash:
          fetchurl {
            url = "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/${revision}/${name}";
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

    meta = {
      description = "NVIDIA Parakeet TDT 0.6B v3 speech-recognition model, int8 ONNX export";
      homepage = "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx";
      license = lib.licenses.cc-by-40;
      platforms = lib.platforms.all;
    };
  }
