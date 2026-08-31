# Settings shared by the Linux and darwin voxtype modules.
{
  settings = pkgs: {
    engine = "parakeet";

    parakeet = {
      model = "${pkgs.parakeet-tdt-onnx}";
    };
  };
}
