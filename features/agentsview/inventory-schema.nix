{
  hostConfig,
  lib,
  ...
}: let
  inherit (import ./common.nix {inherit lib;}) domainType machineType relativePath;
in {
  options.agentsview = with lib; {
    archive = {
      enable = mkEnableOption "the user's AgentsView archive";
      publish = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the user's archive is uploaded to the shared database.";
      };
      secretsFile = mkOption {
        type = relativePath;
        default = "${hostConfig.name}/user-agentsview.yaml";
        description = "File in the secrets repository containing the archive's token, cursor secret and client key.";
      };
    };
    embeddings = mkOption {
      type = types.nullOr (types.enum ["openrouter" "local"]);
      default = null;
      description = "Embedding provider for this host's user archive.";
    };
    server = {
      enable = mkEnableOption "the shared AgentsView database";
      domain = mkOption {
        type = types.nullOr domainType;
        default = null;
        description = "Domain of the shared database's TLS endpoint.";
      };
      secretsFile = mkOption {
        type = relativePath;
        default = "${hostConfig.name}/host-agentsview.yaml";
        description = "File in the secrets repository containing the database and dashboard secrets.";
      };
    };
    publishers = mkOption {
      type = types.attrsOf (types.submodule ({
        name,
        config,
        ...
      }: {
        options = {
          machine = mkOption {
            type = machineType;
            default = name;
            description = "Archive identity and database role.";
          };
          certificate = mkOption {
            type = relativePath;
            description = "Certificate path relative to the dotfiles checkout.";
          };
          passwordFile = mkOption {
            type = relativePath;
            default = "agentsview-postgres/${config.machine}.yaml";
            description = "File in the secrets repository containing the database password.";
          };
          secretsFile = mkOption {
            type = relativePath;
            description = "File in the secrets repository containing the client key.";
          };
          optional = mkOption {
            type = types.bool;
            default = false;
            description = "Whether deployment skips this identity until its credentials exist.";
          };
        };
      }));
      default = {};
      description = "Additional archives uploaded by services on this host.";
    };
  };
}
