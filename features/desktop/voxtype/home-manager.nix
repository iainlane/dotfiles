{pkgs, ...}: {
  _module.args.voxtypeSettings = {
    engine = "parakeet";

    parakeet = {
      model = "${pkgs.parakeet-tdt-onnx}";
    };

    output.notification.on_transcription = false;

    text.spoken_punctuation = true;
  };
}
