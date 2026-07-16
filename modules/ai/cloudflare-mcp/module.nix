# Remote Cloudflare servers that need no local secret. The documentation
# server is open; the account server runs an interactive OAuth flow through
# mcp-remote and caches the token itself. The `dotfiles.ai` options only
# exist when the host also composes the `ai` feature.
{
  lib,
  options,
  pkgs,
  ...
}: let
  mcpRemote = import ../mcp-remote.nix {inherit lib pkgs;};
in {
  config = lib.optionalAttrs (options ? dotfiles && options.dotfiles ? ai) {
    dotfiles.ai.mcpServers = {
      cloudflare = mcpRemote.mkServer {
        name = "cloudflare";
        url = "https://mcp.cloudflare.com/mcp";
      };

      cloudflare-docs = mcpRemote.mkServer {
        name = "cloudflare-docs";
        url = "https://docs.mcp.cloudflare.com/mcp";
      };
    };
  };
}
