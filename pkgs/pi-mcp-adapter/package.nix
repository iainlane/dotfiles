# To update: nix run .#update-pi-mcp-adapter
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-mcp-adapter";
  source = ./source.json;
  npmRoot = ./npm-deps;
  gitHub = {
    owner = "nicobailon";
    repo = "pi-mcp-adapter";
  };
  description = "MCP (Model Context Protocol) adapter extension for Pi coding agent";
}
