{
  config,
  pkgs-unstable,
  ...
}: let
  localhost = "127.0.0.1";
  ollamaPort = toString config.services.ollama.port;
in {
  services = {
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
}
