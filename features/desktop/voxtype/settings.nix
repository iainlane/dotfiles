# Voxtype settings shared by the darwin and Linux modules. Each of those adds
# the parts that only apply to its platform.
{pkgs}: {
  engine = "parakeet";

  parakeet = {
    model = "${pkgs.parakeet-tdt-onnx}";
  };

  output.notification.on_transcription = false;

  text.spoken_punctuation = true;
}
