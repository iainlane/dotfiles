{
  declareSopsSecrets ? true,
  excludedServers ? [],
  inputs,
  lib,
  pkgs,
  pkgs-unstable,
  secretPath ? null,
}: {
  config,
  hostname,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit inputs lib pkgs pkgs-unstable;};
  resolvedSecretPath =
    if secretPath != null
    then secretPath
    else name: config.sops.secrets.${name}.path;
  secretServers = mcp.hostSecretServers {
    inherit declareSopsSecrets;
    inherit hostname;
    secretPath = resolvedSecretPath;
  };

  servers =
    mcp.excludeServers excludedServers
    (mcp.servers // secretServers.servers);
in {
  options.dotfiles.ai.mcpServers = mcp.mcpServersOption;

  config = lib.mkMerge [
    {dotfiles.ai.mcpServers = servers;}

    (lib.mkIf (secretServers.sopsSecrets != {}) {
      sops.secrets = secretServers.sopsSecrets;
    })
  ];
}
