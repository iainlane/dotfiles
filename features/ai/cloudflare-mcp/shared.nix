# Remote Cloudflare servers that need no local secret. The documentation
# server is open; each MCP client owns the account server's interactive OAuth
# flow and credentials.
{lib, ...}: let
  remoteServers = import ../mcp-remote-servers.nix;
in {
  dotfiles.ai.mcpServers = lib.genAttrs ["cloudflare" "cloudflare-docs"] (name: {
    inherit (remoteServers.${name}) url;
  });
}
