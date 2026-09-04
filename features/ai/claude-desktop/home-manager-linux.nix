{
  config,
  mcp,
  pkgs,
  inputs,
  lib,
  ...
}: {
  imports = [./options.nix];

  home.packages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop
  ];

  xdg.configFile."Claude/claude_desktop_config.json" = {
    # The app itself seems to manage to clobber this file.
    force = true;
    source = import ./config-file.nix {inherit config lib mcp pkgs;};
  };
}
