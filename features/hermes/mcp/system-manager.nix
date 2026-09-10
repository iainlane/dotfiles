# The default MCP server set the agent can call: Exa, Cloudflare, Context7 and
# a local mcp-nixos.
{
  config,
  inputs,
  lib,
  mcp,
  ...
}: let
  localNames = ["git" "nixos"];
  cfg = config.dotfiles.hermes;
  remoteServers = import ../../ai/mcp-remote-servers.nix;
  hasKey = key:
    cfg.secretEnvFile
    != null
    && (import ../../../lib/sops-keys.nix {inherit lib;}).hasKey
    (inputs.secrets + "/${cfg.secretEnvFile}")
    key;
  tokens = lib.filterAttrs (_: hasKey) cfg.mcp.tokens;
  tokenTakers = lib.filterAttrs (_: server: server ? token) remoteServers;
  unknownTokens = lib.subtractLists (lib.attrNames tokenTakers) (lib.attrNames cfg.mcp.tokens);
  tokenEnvironment = name: "MCP_${lib.toUpper (builtins.replaceStrings ["-"] ["_"] name)}_TOKEN";
  remoteServer = name: server:
    {inherit (server) url;}
    // lib.optionalAttrs (server ? token && tokens ? ${name}) {
      headers.${server.token.header} = "${server.token.prefix or ""}\${${tokenEnvironment name}}";
    };
  reachable = lib.filterAttrs (name: server: !(server.needsAuth or false) || tokens ? ${name}) remoteServers;
  withoutEmpty = lib.filterAttrs (_: value: value != {} && value != []);
  withSampling =
    lib.mapAttrs (_: server:
      lib.recursiveUpdate {sampling.enabled = lib.mkDefault true;} server);
in {
  config = {
    dotfiles.hermes = {
      mcp.present = true;
      mcp.tokens.exa = lib.mkDefault "exa_api_key";
      settings.mcp_servers =
        withSampling (lib.mapAttrs remoteServer reachable
          // lib.mapAttrs (_: withoutEmpty) (lib.getAttrs localNames mcp.servers));
      agentPackages = lib.attrValues (lib.getAttrs localNames mcp.serverPackages);
      secretEnv = lib.mapAttrs' (name: key: lib.nameValuePair (tokenEnvironment name) key) tokens;
    };

    assertions = [
      {
        assertion = unknownTokens == [];
        message = ''
          dotfiles.hermes.mcp.tokens configures ${lib.concatStringsSep ", " unknownTokens},
          but those MCP servers do not define static-token authentication.
        '';
      }
    ];
  };
}
