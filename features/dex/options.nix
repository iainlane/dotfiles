{lib, ...}: {
  options.services.dex = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      example = "ancaster/host-dex.yaml";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file holding
        the credentials for the connector and for every client. Dex runs as a
        system service, so this file is encrypted to the host key.
      '';
    };

    expose = lib.mkOption {
      type = lib.types.submodule (import ../../lib/exposed-service.nix);
      description = ''
        How the reverse proxy serves the provider. Signing in happens here, so
        `auth` belongs off: a sign-in gate in front of the thing that answers
        it would have nowhere to send anyone.
      '';
    };

    github = {
      clientIdKey = lib.mkOption {
        type = lib.types.str;
        default = "dex_github_client_id";
        description = "Key in `secretsFile` holding the GitHub OAuth app's client ID.";
      };

      clientSecretKey = lib.mkOption {
        type = lib.types.str;
        default = "dex_github_client_secret";
        description = "Key in `secretsFile` holding the GitHub OAuth app's client secret.";
      };

      orgs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        example = ["some-org"];
        description = ''
          GitHub organisations whose members may sign in. Left empty, any
          GitHub account can, and which of them a site serves is then decided
          by the proxy's own list of identities.
        '';
      };
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = ''
        Extra keys merged into the generated `dex.yaml`, overriding what this
        profile sets.
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
