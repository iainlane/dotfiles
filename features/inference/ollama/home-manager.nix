# On Darwin, Home Manager's own `services.ollama` (unlike the NixOS module of
# the same name) has no `loadModels`, so this pulls the declared models itself
# through a launchd agent mirroring the NixOS module's `ollama-model-loader`:
# one `ollama pull` per model, run in parallel up to the core count.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.ollama;
  ollamaModels = config.dotfiles.inference.ollama.models;

  ollama = lib.getExe cfg.package;
  nproc = lib.getExe' pkgs.coreutils "nproc";
  xargs = lib.getExe' pkgs.findutils "xargs";

  logDir = "${config.home.homeDirectory}/Library/Logs";
in {
  config = lib.mkMerge [
    {
      services.ollama = {
        enable = true;
        environmentVariables.OLLAMA_MODELS = "${config.home.homeDirectory}/.ollama/models";
      };
    }

    (lib.mkIf (ollamaModels != []) {
      launchd.agents.ollama-model-loader = {
        enable = true;
        config = {
          ProgramArguments = [
            "/bin/sh"
            "-c"
            ''printf '%s\0' ${lib.escapeShellArgs ollamaModels} | '${xargs}' -0 -r -n 1 -P "$('${nproc}')" '${ollama}' pull''
          ];
          EnvironmentVariables.OLLAMA_HOST = "${cfg.host}:${toString cfg.port}";
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
          StandardOutPath = "${logDir}/ollama-model-loader.log";
          StandardErrorPath = "${logDir}/ollama-model-loader.log";
        };
      };
    })
  ];
}
