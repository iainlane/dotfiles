{pkgs-unstable, ...}: {
  hardware.graphics.enable = true;

  services.ollama = {
    enable = true;
    package = pkgs-unstable.ollama-vulkan;
    host = "127.0.0.1";
    openFirewall = false;
    loadModels = [
      # General purpose chat + vision
      "qwen3.5:27b"
      # Coding
      "devstral-small-2"
      # Fast tasks
      "qwen3:4b"
      # Vision
      "qwen3-vl:8b"
      # Embedding
      "qwen3-embedding:0.6b"
    ];
  };
}
