{
  config,
  hostConfig,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}: let
  cfg = config.services.ollama;
  models = config.dotfiles.inference.ollama.models;

  loader = pkgs.writeShellApplication {
    name = "ollama-model-loader";
    runtimeInputs = [cfg.package pkgs.coreutils];
    text = ''
      export OLLAMA_HOST=${lib.escapeShellArg "${cfg.host}:${toString cfg.port}"}

      deadline=$((SECONDS + 60))
      until ollama list >/dev/null 2>&1; do
        if ((SECONDS >= deadline)); then
          echo "Ollama did not become ready at $OLLAMA_HOST" >&2
          exit 1
        fi

        sleep 1
      done

      ${lib.concatMapStringsSep "\n" (model: ''
          ollama pull ${lib.escapeShellArg model.name}
          ${lib.concatMapStringsSep "\n" (alias: "ollama cp ${lib.escapeShellArgs [model.name alias]}") model.aliases}
        '')
        models}
    '';
  };
in {
  services.ollama = {
    enable = hostConfig.os != "nixos";
    package = lib.mkDefault pkgs-unstable.ollama-vulkan;
  };

  home.packages = [cfg.package];

  systemd.user.services.ollama-model-loader = lib.mkIf (models != []) {
    Unit = {
      Description = "Download the declared Ollama models and create their aliases";
      After = lib.optional cfg.enable "ollama.service";
      Requires = lib.optional cfg.enable "ollama.service";
    };

    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe loader;
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
      TimeoutStartSec = "infinity";
    };

    Install.WantedBy = ["default.target"];
  };
}
