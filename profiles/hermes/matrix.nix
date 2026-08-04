# The Matrix platform: how the agent reaches a homeserver and logs in to it.
#
# The homeserver is the `matrix` profile, which runs Continuwuity as a system
# service and serves it at a public name. The agent connects to that name like
# any other client would, so it needs the bot account's password and the list of
# users allowed to talk to it, and nothing about where the homeserver runs.
{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.services.hermes-agent;
  matrixSecretsFile = inputs.secrets + "/${cfg.matrix.secretsFile}";
  usingRecoveryKey = cfg.matrix.encryption.enable && cfg.matrix.encryption.recoveryKeyKey != null;

  # With no recovery key in the secrets file, the bot bootstraps cross-signing
  # itself: on the first encrypted run it writes the generated recovery key
  # here (a path inside the state volume, mounted at /data in the container),
  # and every later start reads it back into MATRIX_RECOVERY_KEY so the bot
  # can re-sign its device after key rotation.
  bootstrappingKeys = cfg.matrix.encryption.enable && !usingRecoveryKey;
  recoveryKeyStatePath = ".hermes/matrix-recovery-key";
in {
  config = lib.mkIf (cfg.enable && cfg.matrix.enable) {
    services.hermes-agent = {
      extraDependencyGroups = ["matrix"];
      environment =
        {
          MATRIX_HOMESERVER = cfg.matrix.httpUrl;
          MATRIX_USER_ID = "@${cfg.matrix.username}:${cfg.matrix.serverName}";
        }
        // lib.optionalAttrs (cfg.matrix.homeRoom != "") {
          MATRIX_HOME_ROOM = cfg.matrix.homeRoom;
        }
        // lib.optionalAttrs cfg.matrix.encryption.enable {
          MATRIX_E2EE_MODE = "required";
          MATRIX_DEVICE_ID = cfg.matrix.encryption.deviceId;
        }
        // lib.optionalAttrs bootstrappingKeys {
          MATRIX_RECOVERY_KEY_OUTPUT_FILE = "/data/${recoveryKeyStatePath}";
        };
      environmentFiles = [config.sops.templates."hermes-matrix.env".path];
      environmentFromState = lib.optionalAttrs bootstrappingKeys {
        MATRIX_RECOVERY_KEY = recoveryKeyStatePath;
      };
    };

    sops = {
      secrets =
        {
          matrix_password.sopsFile = matrixSecretsFile;
          matrix_allowed_users.sopsFile = matrixSecretsFile;
        }
        // lib.optionalAttrs usingRecoveryKey {
          ${cfg.matrix.encryption.recoveryKeyKey}.sopsFile = matrixSecretsFile;
        };

      # The agent logs in by password; the user ID and home room are not secret
      # and ride along as plain environment.
      templates."hermes-matrix.env".content =
        ''
          MATRIX_PASSWORD=${config.sops.placeholder.matrix_password}
          MATRIX_ALLOWED_USERS=${config.sops.placeholder.matrix_allowed_users}
        ''
        + lib.optionalString usingRecoveryKey ''
          MATRIX_RECOVERY_KEY=${config.sops.placeholder.${cfg.matrix.encryption.recoveryKeyKey}}
        '';
    };
  };
}
