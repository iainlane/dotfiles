# Arbitrary secret environment variables, mapped from environment variable name
# to the sops key containing its value and rendered into the agent's
# environment.
{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
in {
  config = lib.mkIf (cfg.secretEnvFile != null && cfg.secretEnv != {}) {
    sops = {
      secrets =
        lib.mapAttrs' (
          _: sopsKey:
            lib.nameValuePair sopsKey {
              sopsFile = inputs.secrets + "/${cfg.secretEnvFile}";
            }
        )
        cfg.secretEnv;

      templates."hermes-secret.env".content =
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList
          (envVar: sopsKey: "${envVar}=${config.sops.placeholder.${sopsKey}}")
          cfg.secretEnv
        )
        + "\n";
    };

    dotfiles.hermes.environmentFiles = [
      config.sops.templates."hermes-secret.env".path
    ];
  };
}
