{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.dex = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "${hostConfig.name}/host-dex.yaml";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file
        containing the credentials for the connector and for every client. Dex
        runs as a system service, so this file is encrypted to the host key.
      '';
    };

    expose = lib.mkOption {
      type = lib.types.submodule (import ../../lib/exposed-service.nix);
      description = ''
        How the reverse proxy serves the provider. Signing in happens here, so
        `auth` has to be off: a sign-in gate in front of Dex would stop an
        unauthenticated visitor from reaching the provider they need in order
        to sign in.
      '';
    };

    github = {
      clientIdKey = lib.mkOption {
        type = lib.types.str;
        default = "dex_github_client_id";
        description = "Key in `secretsFile` containing the GitHub OAuth app's client ID.";
      };

      clientSecretKey = lib.mkOption {
        type = lib.types.str;
        default = "dex_github_client_secret";
        description = "Key in `secretsFile` containing the GitHub OAuth app's client secret.";
      };

      orgs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        example = ["some-org"];
        description = ''
          GitHub organisations whose members may sign in. With the list empty,
          any GitHub account can sign in, and which of those accounts a site
          serves is left to the proxy's own allow-list.
        '';
      };
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = ''
        Extra keys merged into the generated `dex.yaml`, overriding what this
        feature sets.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Dex package to run. Defaults to `pkgs.dex-oidc`.";
    };

    containerName = lib.mkOption {
      type = lib.types.str;
      default = "dex";
      description = "Name of the Dex podman container, and the name the proxy resolves it by.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5556;
      description = "Port Dex listens on inside the container.";
    };
  };
}
