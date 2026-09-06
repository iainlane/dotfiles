# The default MCP server set the agent can call: Exa, Cloudflare, Context7 and
# a local mcp-nixos.
{
  lib,
  pkgs,
  ...
}: let
  withSampling =
    lib.mapAttrs (_: server:
      lib.recursiveUpdate {sampling.enabled = lib.mkDefault true;} server);
in {
  config = {
    dotfiles.hermes.mcp.present = true;

    dotfiles.hermes.settings.mcp_servers = withSampling {
      exa = {
        url = "https://mcp.exa.ai/mcp";
        # Authenticate with the Exa key, which takes these requests off the
        # free tier. Hermes expands ${EXA_API_KEY} from the environment when it
        # loads the config, so the key never reaches the world-readable store.
        # The MCP SDK's URL handling drops a `?exaApiKey=` query parameter, so
        # the key goes in a header instead.
        headers."x-api-key" = "\${EXA_API_KEY}";
      };
      cloudflare.url = "https://docs.mcp.cloudflare.com/mcp";
      context7.url = "https://mcp.context7.com/mcp";
      nixos = {
        command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
        args = [];
      };
    };
  };
}
