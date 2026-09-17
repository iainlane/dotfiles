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

  pullNames = map (model: model.name) ollamaModels;

  # Runs after every model has pulled, so the source model for each alias
  # already exists. `ollama cp` is a cheap local rename, so these run one
  # at a time.
  aliasCommands =
    lib.concatMapStrings (
      model:
        lib.concatMapStrings
        (alias: "'${ollama}' cp ${lib.escapeShellArg model.name} ${lib.escapeShellArg alias} && ")
        model.aliases
    )
    ollamaModels;
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
            ''printf '%s\0' ${lib.escapeShellArgs pullNames} | '${xargs}' -0 -r -n 1 -P "$('${nproc}')" '${ollama}' pull && ${aliasCommands}true''
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
