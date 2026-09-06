# The Cloudflare MCP servers: the account-level server and the documentation
# server. Cloudflare is personal infrastructure, so features include this on
# the hosts that should reach it. The MCP server set is read at both the Home
# Manager and the OS level, so the module is registered for every target.
#
# `ai` does not include this child, so the child includes `ai`: the servers
# are defined under `dotfiles.ai.mcpServers`, which `ai` declares.
{config, ...}: {
  flake.features.ai.provides.cloudflare-mcp = {
    includes = [config.flake.features.ai];

    homeManager = ./shared.nix;
    system = ./shared.nix;
  };
}
