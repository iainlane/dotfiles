# The Matrix platform: how the agent reaches a homeserver and logs in to it.
#
# The homeserver comes from the `matrix` feature, which runs Continuwuity as a
# system service and serves it at a public name. The agent connects to that
# name as any other client would, so it needs the bot account's password and
# the list of users allowed to talk to it, and nothing about where the
# homeserver runs.
#
# Both features declare sops secrets in the same host configuration, one to
# create the bot account and one to log in with. The agent's secret names are
# prefixed with `hermes_` so they do not collide with the homeserver's, and
# each one sets `key` explicitly to read the shared value.
{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
  matrixSecretsFile = inputs.secrets + "/${cfg.matrix.secretsFile}";
  usingRecoveryKey = cfg.matrix.encryption && cfg.matrix.recoveryKeyKey != null;

  # With no recovery key in the secrets file, the bot bootstraps cross-signing
  # itself: on the first encrypted run it writes the generated recovery key
  # here (a path inside the state volume, mounted at /data in the container),
  # and every later start reads it back into MATRIX_RECOVERY_KEY so the bot
  # can re-sign its device after key rotation.
  bootstrappingKeys = cfg.matrix.encryption && !usingRecoveryKey;
  recoveryKeyStatePath = ".hermes/matrix-recovery-key";
in {
  config = {
    dotfiles.hermes.matrix.present = true;

    dotfiles.hermes = {
      extraDependencyGroups = ["matrix"];
      settings.display.platforms.matrix.streaming = lib.mkDefault true;
      environment =
        {
          MATRIX_HOMESERVER = cfg.matrix.httpUrl;
          MATRIX_USER_ID = "@${cfg.matrix.username}:${cfg.matrix.serverName}";
        }
        // lib.optionalAttrs (cfg.matrix.homeRoom != "") {
          MATRIX_HOME_ROOM = cfg.matrix.homeRoom;
        }
        // lib.optionalAttrs cfg.matrix.encryption {
          MATRIX_E2EE_MODE = "required";
          MATRIX_DEVICE_ID = cfg.matrix.deviceId;
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
          hermes_matrix_password = {
            sopsFile = matrixSecretsFile;
            key = "matrix_password";
          };

          hermes_matrix_allowed_users = {
            sopsFile = matrixSecretsFile;
            key = "matrix_allowed_users";
          };
        }
        // lib.optionalAttrs usingRecoveryKey {
          hermes_matrix_recovery_key = {
            sopsFile = matrixSecretsFile;
            key = cfg.matrix.recoveryKeyKey;
          };
        };

      # The agent logs in by password. The user ID and home room are not secret
      # and are set as plain environment variables.
      templates."hermes-matrix.env".content =
        ''
          MATRIX_PASSWORD=${config.sops.placeholder.hermes_matrix_password}
          MATRIX_ALLOWED_USERS=${config.sops.placeholder.hermes_matrix_allowed_users}
        ''
        + lib.optionalString usingRecoveryKey ''
          MATRIX_RECOVERY_KEY=${config.sops.placeholder.hermes_matrix_recovery_key}
        '';
    };
  };
}
