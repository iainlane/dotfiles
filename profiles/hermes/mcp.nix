# The default MCP server set the agent can call: Exa, Cloudflare, Context7 and
# a local mcp-nixos.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
in {
  config = lib.mkIf (cfg.enable && cfg.mcp.enable) {
    services.hermes-agent.settings.mcp_servers = {
      exa = {
        url = "https://mcp.exa.ai/mcp";
        # Authenticate with the Exa key (off the free tier). Hermes
        # expands ${EXA_API_KEY} from the env at load, so the secret never
        # reaches the world-readable store; the header survives the MCP
        # SDK's URL handling where a ?exaApiKey= query param would not.
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
