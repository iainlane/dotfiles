{lib, ...}: {
  options.dotfiles.hermes.mcp.tokens = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Sops keys for static MCP API tokens, indexed by server name.";
  };
}
