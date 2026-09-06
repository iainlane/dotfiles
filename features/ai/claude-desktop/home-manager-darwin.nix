{
  config,
  mcp,
  pkgs,
  lib,
  ...
}: {
  imports = [./options.nix];

  home.file."Library/Application Support/Claude/claude_desktop_config.json" = {
    # Claude Desktop rewrites this file itself, so home-manager replaces it.
    force = true;
    source = import ./config-file.nix {inherit config lib mcp pkgs;};
  };
}
