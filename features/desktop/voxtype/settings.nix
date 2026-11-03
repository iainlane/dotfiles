# Voxtype settings shared by the darwin and Linux modules. Each of those adds
# the parts that only apply to its platform.
{pkgs}: {
  engine = "parakeet";

  parakeet = {
    model = "${pkgs.parakeet-unified-onnx}";
    streaming = true;
    streaming_chunk_secs = 0.32;
    streaming_left_context_secs = 5.6;
    streaming_right_context_secs = 0.32;
  };

  output.notification.on_transcription = false;

  text.spoken_punctuation = true;
}
