# Arbitrary secret environment variables, mapped from environment variable name
# to the sops key holding its value and rendered into the agent's environment.
{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.services.hermes-agent;
in {
  config = lib.mkIf (cfg.enable && cfg.secretEnvFile != null && cfg.secretEnv != {}) {
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

    services.hermes-agent.environmentFiles = [
      config.sops.templates."hermes-secret.env".path
    ];
  };
}
