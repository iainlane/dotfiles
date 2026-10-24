{pkgs-unstable, ...}: let
  rea = import ./runtime.nix {pkgs = pkgs-unstable;};
in {
  dotfiles.ai.mcpServers.rea = {
    command = "${rea}/bin/rea";
    args = ["mcp"];
  };
}
