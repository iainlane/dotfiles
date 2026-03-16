_: {
  flake.profiles.inference = {
    homeManagerModule = {pkgs, ...}: {
      home.packages = with pkgs; [
        aichat
        mods
        oterm
      ];
    };

    nixosModule = {
      config,
      pkgs,
      pkgs-unstable,
      ...
    }: let
      localhost = "127.0.0.1";
      ollamaPort = toString config.services.ollama.port;
    in {
      services = {
        ollama = {
          enable = true;
          package = pkgs-unstable.ollama-vulkan;
          host = localhost;
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

        open-webui = {
          enable = true;
          package = pkgs-unstable.open-webui;
          host = localhost;
          port = 8080;
          environment = {
            OLLAMA_BASE_URLS = "http://${localhost}:${ollamaPort}";
            ENABLE_SIGNUP = "true";
            ENABLE_LOGIN_FORM = "true";
            DEFAULT_USER_ROLE = "user";
            ENABLE_IMAGE_GENERATION = "false";
            ENABLE_EVALUATION_ARENA_MODELS = "false";
            WEBUI_NAME = "${config.networking.hostName} Chat";
          };
        };

        tika = {
          enable = true;
          listenAddress = localhost;
        };
      };

      environment.systemPackages = with pkgs; [
        clinfo
        nvtopPackages.amd
        vulkan-tools
        amdgpu_top
      ];
    };
  };
}
