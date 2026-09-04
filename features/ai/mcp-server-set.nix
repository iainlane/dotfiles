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
    hostname = hostConfig.name;
    secretPath = resolvedSecretPath;
  };

  servers = mcp.servers // secretServers.servers;
in {
  options.dotfiles.ai.mcpServers = mcp.mcpServersOption;

  config = lib.mkMerge [
    {dotfiles.ai.mcpServers = servers;}

    (lib.mkIf (secretServers.sopsSecrets != {}) {
      sops.secrets = secretServers.sopsSecrets;
    })
  ];
}
