{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
in {
  options.dotfiles.hermes.signal = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = cfg.secretsFile;
      defaultText = lib.literalExpression "config.dotfiles.hermes.secretsFile";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file
        holding `signal_account`, `signal_allowed_users` and
        `signal_home_channel`.
      '';
    };

    httpUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://signal-cli:8080";
      description = "URL at which Hermes reaches the signal-cli daemon.";
    };

    network = lib.mkOption {
      type = lib.types.str;
      default = "hermesnet";
      description = "Podman network shared between Hermes and signal-cli.";
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "signal-cli package to run. Defaults to `pkgs.signal-cli`.";
    };

    containerName = lib.mkOption {
      type = lib.types.str;
      default = "signal-cli";
      description = "Name of the signal-cli podman container.";
    };
  };
}
