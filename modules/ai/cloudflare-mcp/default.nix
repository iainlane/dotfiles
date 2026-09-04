# The Cloudflare MCP servers: the account-level server and the documentation
# server. Cloudflare is personal infrastructure, so features include this on
# the hosts that should reach it. The MCP server set is read at both the Home
# Manager and the OS level, so the module is registered for every target.
{
  flake.features."cloudflare-mcp" = {
    homeManager = ./module.nix;
    system = ./module.nix;
  };
}
