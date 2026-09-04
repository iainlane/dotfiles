{
  config,
  pkgs-unstable,
  ...
}: let
  localhost = "127.0.0.1";
  ollamaPort = toString config.services.ollama.port;
  tikaPort = toString config.services.tika.port;
in {
  services = {
    open-webui = {
      enable = true;
      package = pkgs-unstable.open-webui;
      host = localhost;
      port = 8080;
      # Defining this option replaces the nixpkgs module's default, which
      # sets the three telemetry opt-outs below. They must be repeated.
      environment = {
        ANONYMIZED_TELEMETRY = "False";
        DO_NOT_TRACK = "True";
        SCARF_NO_ANALYTICS = "True";

        OLLAMA_BASE_URLS = "http://${localhost}:${ollamaPort}";
        ENABLE_SIGNUP = "true";
        ENABLE_LOGIN_FORM = "true";
        DEFAULT_USER_ROLE = "user";
        ENABLE_IMAGE_GENERATION = "false";
        ENABLE_EVALUATION_ARENA_MODELS = "false";
        WEBUI_NAME = "${config.networking.hostName} Chat";

        CONTENT_EXTRACTION_ENGINE = "tika";
        TIKA_SERVER_URL = "http://${localhost}:${tikaPort}";
      };
    };

    tika = {
      enable = true;
      listenAddress = localhost;
    };
  };
}
