{
  browser-rendering = {
    url = "https://browser.mcp.cloudflare.com/mcp";
    needsAuth = true;
    token.header = "Authorization";
    token.prefix = "Bearer ";
  };
  cloudflare = {
    url = "https://mcp.cloudflare.com/mcp";
    needsAuth = true;
  };
  cloudflare-docs.url = "https://docs.mcp.cloudflare.com/mcp";
  context7.url = "https://mcp.context7.com/mcp";
  exa = {
    url = "https://mcp.exa.ai/mcp";
    token.header = "x-api-key";
  };
}
