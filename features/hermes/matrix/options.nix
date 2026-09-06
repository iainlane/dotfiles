{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
in {
  options.dotfiles.hermes.matrix = {
    serverName = lib.mkOption {
      type = lib.types.str;
      example = "example.org";
      description = ''
        Domain suffix of the bot's user ID (`@<username>:<serverName>`). This
        is the homeserver's `server_name`, which identifies it and is not
        necessarily the name it is reached at. `httpUrl` gives that name.
      '';
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = ''
        Local part of the bot's Matrix user ID; the full ID is
        `@<username>:<serverName>`. The bootstrap step creates this account
        and the agent logs in as it.
      '';
    };

    displayName = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "Godfrey";
      description = ''
        Display name set on the bot's Matrix profile. Null leaves whatever the
        account already has (the lowercase local part from account creation).
      '';
    };

    homeRoom = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "!abcdef:matrix.orangesquash.org.uk";
      description = ''
        Optional room ID for cron and notification delivery. With this empty
        the bot still works in DMs and threads; set it once you have a room for
        unsolicited output.
      '';
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = cfg.secretsFile;
      defaultText = lib.literalExpression "config.dotfiles.hermes.secretsFile";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file
        containing `matrix_password` (the bot account's password, which the
        homeserver creates the account with and the agent logs in with) and
        `matrix_allowed_users` (comma-separated user IDs allowed to talk to
        the bot).
      '';
    };

    encryption = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to use end-to-end encryption for the bot's Matrix account.";
    };

    deviceId = lib.mkOption {
      type = lib.types.str;
      default = "hermes-agent";
      description = ''
        Fixed device ID for the bot, so the same device (and its E2EE keys)
        is reused on every login and persists across restarts.
      '';
    };

    recoveryKeyKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "matrix_recovery_key";
      description = ''
        Key in `secretsFile` containing the cross-signing recovery key. With
        this null, the bot bootstraps cross-signing on its first encrypted run
        and keeps the generated recovery key in its state volume, from which
        later runs read it back to re-sign the device after key rotation. Set
        this to take the key from the secrets file instead.
      '';
    };

    httpUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://matrix.example.org";
      description = ''
        URL at which Hermes reaches the homeserver's client-server API. The
        agent is an ordinary client of the homeserver, so this is the public
        name it is served at.
      '';
    };
  };
}
