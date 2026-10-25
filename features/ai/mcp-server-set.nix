{
  declareSopsSecrets ? true,
  secretPath ? null,
}: {
  config,
  hostConfig,
  lib,
  mcp,
  ...
}: let
  resolvedSecretPath =
    if secretPath != null
    then secretPath
    else name: config.sops.secrets.${name}.path;
  secretServers = mcp.hostSecretServers {
    inherit declareSopsSecrets;
    host = hostConfig.name;
    secretPath = resolvedSecretPath;
  };

  servers = mcp.servers // secretServers.servers;
in {
  options.dotfiles.ai = {
    mcpServers = mcp.mcpServersOption;

    mcpNativeServers = lib.mkOption {
      default = {};
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          url = lib.mkOption {type = lib.types.str;};
          sourceCommand = lib.mkOption {type = lib.types.str;};
          headerFiles = lib.mkOption {
            default = {};
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                file = lib.mkOption {type = lib.types.str;};
                prefix = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                };
              };
            });
          };
        };
      });
      description = "Native HTTP metadata for shared MCP servers whose other clients use stdio wrappers. sourceCommand identifies the corresponding shared definition; header files are read only by the host consumer.";
    };
  };

  config = lib.mkMerge [
    {
      dotfiles.ai.mcpServers = servers;
      dotfiles.ai.mcpNativeServers = mcp.nativeServers // secretServers.nativeServers;
    }

    (lib.mkIf (secretServers.sopsSecrets != {}) {
      sops.secrets = secretServers.sopsSecrets;
    })
  ];
}
