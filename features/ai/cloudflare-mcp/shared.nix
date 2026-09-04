# Remote Cloudflare servers that need no local secret. The documentation
# server is open; each MCP client owns the account server's interactive OAuth
# flow and credentials. The `dotfiles.ai` options only exist when the host also
# composes the `ai` feature.
{
  lib,
  options,
  ...
}: {
  config = lib.optionalAttrs (options ? dotfiles && options.dotfiles ? ai) {
    dotfiles.ai.mcpServers = {
      cloudflare.url = "https://mcp.cloudflare.com/mcp";
      cloudflare-docs.url = "https://docs.mcp.cloudflare.com/mcp";
    };
  };
}
