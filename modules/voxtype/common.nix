# Settings shared by the Linux and darwin voxtype modules.
{
  settings = pkgs: {
    engine = "parakeet";

    parakeet = {
      model = "${pkgs.parakeet-tdt-onnx}";

      # Auto-detection only recognises the fp32 file names, not the int8
      # ones, and warns before defaulting to TDT.
      model_type = "tdt";
    };

    text.spoken_punctuation = true;
  };
}
